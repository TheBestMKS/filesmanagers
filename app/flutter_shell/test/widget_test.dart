import 'package:flutter_test/flutter_test.dart';

import 'package:secure_vault_shell/main.dart';

void main() {
  testWidgets('Secure Vault shell boots', (tester) async {
    await tester.pumpWidget(const SecureVaultApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });
}
