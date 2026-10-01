import 'package:PiliPlus/utils/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> release(int code, {String hash = 'released-commit'}) => {
    'target_commitish': hash,
    'created_at': '2099-01-01T00:00:00Z',
    'assets': [
      {'name': 'PiliPlus_android_2.1.6-abcdef123+${code}_arm64-v8a.apk'},
      {'name': 'PiliPlus_windows_2.1.6+${code}_x64_portable.zip'},
    ],
  };

  test('the installed release never offers itself again after publication', () {
    expect(
      Update.isNewerRelease(
        release(5415),
        versionCode: 5415,
        commitHash: 'installed-commit',
      ),
      isFalse,
    );
  });

  test('a newer fork build is detected and older builds are not offered', () {
    expect(
      Update.isNewerRelease(release(5416), versionCode: 5415),
      isTrue,
    );
    expect(
      Update.isNewerRelease(release(5414), versionCode: 5415),
      isFalse,
    );
  });

  test('the same source commit is not an update even after another build', () {
    expect(
      Update.isNewerRelease(
        release(5416, hash: 'installed-commit'),
        versionCode: 5415,
        commitHash: 'installed-commit',
      ),
      isFalse,
    );
  });

  test(
    'legacy release timestamps remain usable and malformed ones are ignored',
    () {
      expect(
        Update.isNewerRelease({
          'created_at': '2026-10-01T00:00:01Z',
        }, buildTime: 0),
        isTrue,
      );
      expect(Update.isNewerRelease({'created_at': 'not a date'}), isFalse);
      expect(Update.isNewerRelease({}), isFalse);
    },
  );
}
