import 'package:flutter_test/flutter_test.dart';

import 'package:filesmanagers/main.dart';

void main() {
  testWidgets('filesmanagers shell boots', (tester) async {
    await tester.pumpWidget(const FilesManagersApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });
}
