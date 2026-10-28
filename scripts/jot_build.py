#!/usr/bin/env python3
"""Standalone Jot build, test, DMG packaging and Developer ID release. Never installs implicitly."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'scripts/app.json'
LOCAL_IDENTITY_VARIABLE = 'JOT_SIGNING_IDENTITY'


def run(command, capture=False):
    return subprocess.run([str(x) for x in command], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def say(message):
    print(message, flush=True)


def compile_binary(sources, executable, config, architectures, scratch):
    slices = []
    frameworks = [item for framework in config['frameworks'] for item in ('-framework', framework)]
    for architecture in architectures:
        output = scratch / (executable.name + '.' + architecture)
        run(['xcrun', 'swiftc', '-O', '-swift-version', config['swift_version'],
             '-target', architecture + '-apple-macos' + config['minimum_macos'],
             *sources, '-o', output, *frameworks])
        slices.append(output)
    if len(slices) == 1:
        shutil.copy2(slices[0], executable)
    else:
        run(['lipo', '-create', *slices, '-output', executable])


def publish_directory(staged, destination):
    """Replace only an explicit output, preserving it until the new copy is ready."""
    backup = destination.with_name(destination.name + '.previous')
    if backup.exists() or backup.is_symlink():
        raise ValueError('Previous replacement needs inspection: {}'.format(backup))
    if destination.is_symlink():
        raise ValueError('Refusing to replace symlink: {}'.format(destination))
    if destination.exists() and not destination.is_dir():
        raise ValueError('Refusing to replace non-directory: {}'.format(destination))
    if destination.exists():
        destination.rename(backup)
    try:
        staged.rename(destination)
    except BaseException:
        if backup.exists():
            backup.rename(destination)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def output_directory(path):
    # An old build/ or dist/ symlink must never redirect cleanup outside this repo.
    if path.resolve() != path:
        raise ValueError('Output path must not contain symlinks: {}'.format(path))
    path.mkdir(parents=True, exist_ok=True)
    return path


def is_running(executable):
    result = subprocess.run(['pgrep', '-x', executable], stdout=subprocess.DEVNULL)
    if result.returncode not in (0, 1):
        raise ValueError('Could not determine whether {} is running'.format(executable))
    return result.returncode == 0


def install_app(config, bundle):
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        executable = plistlib.load(stream)['CFBundleExecutable']
    if is_running(executable):
        raise ValueError('Quit {} before installing. No running app will be replaced.'.format(config['name']))
    applications = Path.home() / 'Applications'
    applications.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.jot-install-', dir=applications) as temporary:
        staged = Path(temporary) / bundle.name
        run(['ditto', bundle, staged])
        run(['codesign', '--verify', '--deep', '--strict', staged], capture=True)
        if is_running(executable):
            raise ValueError('{} started during installation; quit it and retry.'.format(config['name']))
        destination = applications / bundle.name
        publish_directory(staged, destination)
    say('Installed {} (not launched)'.format(destination))
    registrar = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
    if registrar.is_file():
        result = subprocess.run([str(registrar), '-f', str(destination)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode:
            say('Warning: macOS did not refresh this app\'s registration; it may take a new login.')


def signing_identity(requested):
    """--identity wins, then JOT_SIGNING_IDENTITY, then ad-hoc ('-', local use only).

    A stable identity (any code-signing certificate in your keychain) keeps the Accessibility and
    Automation grants macOS ties to the signature across rebuilds; an ad-hoc signature changes every build."""
    return requested or os.environ.get(LOCAL_IDENTITY_VARIABLE) or '-'


def codesign_command(config, identity, target, hardened=None):
    """The codesign call for `target`.

    Local identities (ad-hoc or your own certificate) are signed plainly. A Developer ID identity, or hardened=True
    for someone passing a certificate's hash instead of its name, also gets the hardened runtime, a secure timestamp
    and the app's entitlements, which is what notarization requires. An ad-hoc signature has no certificate to
    timestamp, so a hardened ad-hoc build (a local smoke test of the release configuration) skips the timestamp."""
    command = ['codesign', '--force', '--sign', identity]
    if hardened is None:
        hardened = identity.startswith('Developer ID Application:')
    if hardened:
        command += ['--options', 'runtime']
        if identity != '-':
            command += ['--timestamp']
        if config.get('entitlements'):
            command += ['--entitlements', str(ROOT / config['entitlements'])]
    return command + [str(target)]


def release_commands(name, bundle, zip_path, dmg, identity, profile):
    """The notarization sequence, in the order it must run, as (description, command) pairs.

    The app is notarized and stapled BEFORE it goes into the disk image, then the image itself is signed,
    notarized and stapled, so Gatekeeper accepts both the copied app and the downloaded image."""
    return [
        ('zip the app for upload', ['ditto', '-c', '-k', '--keepParent', bundle, zip_path]),
        ('notarize the app', ['xcrun', 'notarytool', 'submit', zip_path, '--keychain-profile', profile, '--wait']),
        ('staple the app', ['xcrun', 'stapler', 'staple', bundle]),
        ('sign the disk image', ['codesign', '--force', '--sign', identity, '--timestamp', dmg]),
        ('notarize the disk image', ['xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', profile, '--wait']),
        ('staple the disk image', ['xcrun', 'stapler', 'staple', dmg]),
        ('validate the stapled disk image', ['xcrun', 'stapler', 'validate', dmg]),
        ('assess the disk image with Gatekeeper',
         ['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg]),
    ]


def require_release_inputs(identity, profile):
    if not identity or not identity.startswith('Developer ID Application:'):
        raise ValueError('release needs --identity "Developer ID Application: Your Name (TEAMID)"')
    if not profile:
        raise ValueError('release needs --notary-profile NAME (create one with: xcrun notarytool store-credentials NAME)')


def validate_bundle(config, bundle, architectures, release=False):
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    run(['plutil', '-lint', bundle / 'Contents/Info.plist'], capture=True)
    binary = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    actual = set(run(['lipo', '-archs', binary], capture=True).stdout.split())
    if actual != set(architectures):
        raise ValueError('{}: expected {}, found {}'.format(binary, architectures, sorted(actual)))
    run(['codesign', '--verify', '--strict', binary], capture=True)
    run(['codesign', '--verify', '--deep', '--strict', bundle], capture=True)
    if not (bundle / 'Contents/Resources/Jot-LICENSE.txt').is_file():
        raise ValueError('{} does not carry its license'.format(bundle.name))
    if release:
        # Local signatures are useful for development, but are not public releases.
        signature = run(['codesign', '-d', '--verbose=4', bundle], capture=True).stderr
        if 'Authority=Developer ID Application:' not in signature or 'runtime' not in signature:
            raise ValueError('{} needs Developer ID signing with hardened runtime before release'.format(config['name']))
        run(['xcrun', 'stapler', 'validate', bundle])
        run(['spctl', '--assess', '--type', 'execute', '--verbose=2', bundle])
    say('Verified {} ({})'.format(bundle.relative_to(ROOT), ', '.join(architectures)))


def build_app(config, architectures, output, identity, hardened=None):
    _, info = metadata(config)
    say('Building {} for {}'.format(config['name'], ', '.join(architectures)))
    with tempfile.TemporaryDirectory(prefix='.stage-', dir=output) as temporary:
        scratch = Path(temporary)
        bundle = scratch / (config['name'] + '.app')
        macos = bundle / 'Contents/MacOS'
        resources = bundle / 'Contents/Resources'
        macos.mkdir(parents=True)
        resources.mkdir()
        sources = sorted((ROOT / 'Sources').glob('*.swift'))
        compile_binary(sources, macos / info['CFBundleExecutable'], config, architectures, scratch)
        icon = ROOT / 'AppIcon.icns'
        if icon.exists():
            shutil.copy2(icon, resources / icon.name)
        else:
            info.pop('CFBundleIconFile', None)
        with (bundle / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(info, stream)
        shutil.copy2(ROOT / 'LICENSE', resources / 'Jot-LICENSE.txt')
        run(codesign_command(config, identity, bundle, hardened))
        validate_bundle(config, bundle, architectures)
        destination = output / bundle.name
        publish_directory(bundle, destination)
    say('Built {}'.format(destination))
    return destination


def package_app(config, bundle, destination):
    with tempfile.TemporaryDirectory(prefix='.package-', dir=destination) as temporary:
        scratch = Path(temporary)
        stage = scratch / config['name']
        stage.mkdir()
        run(['ditto', bundle, stage / bundle.name])
        (stage / 'Applications').symlink_to('/Applications')
        shutil.copy2(ROOT / 'FIRST_RUN.txt', stage / 'Read Me.txt')
        dmg = scratch / (config['name'] + '.dmg')
        run(['hdiutil', 'create', '-volname', config['name'], '-srcfolder', stage,
             '-format', 'UDZO', dmg], capture=True)
        run(['hdiutil', 'verify', dmg], capture=True)
        final = destination / dmg.name
        if final.is_symlink():
            raise ValueError('Refusing to replace symlink: {}'.format(final))
        os.replace(dmg, final)
    return final


def metadata(config):
    with (ROOT / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleShortVersionString', 'CFBundleVersion'):
        if not info.get(key):
            raise ValueError('Missing metadata: ' + key)
    if info['CFBundleName'] != config['name'] or not info.get('LSUIElement'):
        raise ValueError('Invalid Jot metadata')
    if info['CFBundleExecutable'] != 'Jot' or config['name'] != 'Jot':
        raise ValueError('Invalid Jot executable metadata')
    if info['LSMinimumSystemVersion'] != config['minimum_macos']:
        raise ValueError('Minimum macOS differs from scripts/app.json')
    if not (ROOT / 'Sources/main.swift').is_file():
        raise ValueError('Missing Jot entrypoint')
    if not config['frameworks'] or len(config['frameworks']) != len(set(config['frameworks'])):
        raise ValueError('Invalid framework list')
    for required in ('LICENSE', 'FIRST_RUN.txt'):
        if not (ROOT / required).is_file():
            raise ValueError('Missing ' + required)
    entitlements = config.get('entitlements')
    if entitlements:
        path = (ROOT / entitlements).resolve()
        if ROOT.resolve() not in path.parents or not path.is_file():
            raise ValueError('Entitlements file must be inside the repository: ' + entitlements)
    return ROOT, info


def check_sources(config):
    _, info = metadata(config)
    run(['plutil', '-lint', ROOT / 'Info.plist'], capture=True)
    if config.get('entitlements'):
        run(['plutil', '-lint', ROOT / config['entitlements']], capture=True)
    if not (ROOT / 'AppIcon.icns').is_file():
        say('Warning: no AppIcon.icns; builds use the system icon.')
    for script in sorted(ROOT.glob('*.sh')) + sorted((ROOT / 'scripts').glob('*.sh')):
        run(['bash', '-n', script])
    say('Checked Jot {} ({})'.format(info['CFBundleShortVersionString'], info['CFBundleVersion']))


def run_tests():
    run([sys.executable, ROOT / 'scripts/test_tooling.py'])
    run(['bash', ROOT / 'test.sh'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('build', 'check', 'package', 'release'))
    parser.add_argument('--universal', action='store_true', help='Build both architectures; package and release always do')
    parser.add_argument('--install', action='store_true', help='Explicitly replace ~/Applications/Jot.app after quitting it; never launch')
    parser.add_argument('--identity', help='Signing identity (default: $JOT_SIGNING_IDENTITY, otherwise ad-hoc local signing)')
    parser.add_argument('--built', action='store_true', help='Check the existing built bundle as well as source/tests')
    parser.add_argument('--release', action='store_true', help='Also require Developer ID, hardened runtime and notarization')
    parser.add_argument('--hardened', action='store_true', help='Sign with the hardened runtime and the app\'s entitlements (implied by a Developer ID identity)')
    parser.add_argument('--notary-profile', help='release: the notarytool keychain profile (xcrun notarytool store-credentials NAME)')
    parser.add_argument('--dry-run', action='store_true', help='release: print every step instead of running it')
    args = parser.parse_args()
    if args.install and args.command != 'build':
        parser.error('--install is only valid with build')
    if (args.built or args.release) and args.command != 'check':
        parser.error('--built and --release require check')
    if args.identity and args.command == 'check':
        parser.error('--identity applies to build/package/release')
    if args.hardened and args.command == 'check':
        parser.error('--hardened applies to build/package')
    if (args.notary_profile or args.dry_run) and args.command != 'release':
        parser.error('--notary-profile and --dry-run are only valid with release')
    config = json.loads(CONFIG.read_text())
    check_sources(config)
    universal = args.universal or args.command in ('package', 'release')
    architectures = ['arm64', 'x86_64'] if universal else [platform.machine()]
    if any(a not in ('arm64', 'x86_64') for a in architectures):
        raise ValueError('Jot requires an Apple Silicon or Intel Mac')
    output = ROOT / 'build' / ('universal' if universal else 'native')
    if args.command == 'check':
        run_tests()
        if args.built or args.release:
            validate_bundle(config, output / 'Jot.app', architectures, args.release)
        return
    identity = signing_identity(args.identity)
    if args.command == 'release':
        require_release_inputs(identity, args.notary_profile)
        if args.dry_run:
            bundle, dmg = output / 'Jot.app', ROOT / 'dist/Jot.dmg'
            say('[dry run] test, then build Jot universal signed with {} (hardened runtime, timestamp, entitlements)'.format(identity))
            for description, command in release_commands('Jot', bundle, ROOT / 'dist/Jot.zip', dmg, identity, args.notary_profile):
                say('[dry run] {}: {}'.format(description, ' '.join(shlex.quote(str(part)) for part in command)))
            say('[dry run] check --built --release')
            return
    if args.command in ('package', 'release'):
        run_tests()
    output_directory(output)
    say('Signing: ' + ('ad-hoc (local only)' if identity == '-' else identity))
    hardened = True if (args.hardened or args.command == 'release') else None
    bundle = build_app(config, architectures, output, identity, hardened)
    if args.install:
        install_app(config, bundle)
    if args.command in ('package', 'release'):
        destination = output_directory(ROOT / 'dist')
        dmg = destination / 'Jot.dmg'
        if args.command == 'release':
            zip_path = destination / 'Jot.zip'
            steps = release_commands('Jot', bundle, zip_path, dmg, identity, args.notary_profile)
            for description, command in steps[:3]:      # notarize and staple the app first...
                say('Release: ' + description)
                run(command)
            package_app(config, bundle, destination)    # ...so the image carries the stapled app...
            for description, command in steps[3:]:      # ...then sign, notarize and staple the image.
                say('Release: ' + description)
                run(command)
            zip_path.unlink(missing_ok=True)
            validate_bundle(config, bundle, architectures, release=True)
            say('Released {}'.format(dmg))
        else:
            say('Packaged {} (local preview; not notarized)'.format(package_app(config, bundle, destination)))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('error: {}'.format(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
