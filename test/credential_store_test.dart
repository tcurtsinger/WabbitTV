import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a malformed stored serverUrl is dropped, not thrown', () async {
    FlutterSecureStorage.setMockInitialValues({
      'bad-url': '{"username":"u","password":"p","serverUrl":42}',
      'not-json': '{',
    });
    final store = SecureCredentialStore();

    final stored = await store.read('bad-url');
    expect(stored?.username, 'u');
    expect(stored?.password, 'p');
    expect(stored?.serverUrl, isNull);
    expect(await store.read('not-json'), isNull);
  });
}
