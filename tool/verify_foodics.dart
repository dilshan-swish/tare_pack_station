// One-off live verification of the Dart FoodicsApi against the real API.
// Run: dart run tool/verify_foodics.dart
// Reads the MM token from the local keys file (never printed).
import 'dart:io';
import 'package:tare_pack_station/data/foodics_api.dart';

Future<void> main() async {
  final file = File('# FOODICS BRAND API KEYS.txt');
  String token = '';
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('FOODICS_API_KEY_MM=')) {
      token = line.substring('FOODICS_API_KEY_MM='.length).trim();
    }
  }
  if (token.isEmpty) {
    stderr.writeln('token not found');
    exit(1);
  }
  final api = FoodicsApi(baseUrl: 'https://api.foodics.com/v5', token: token);
  try {
    final branches = await api.listBranches();
    stdout.writeln('branches: ${branches.length}');
    // Find a branch with open orders.
    for (final b in branches) {
      final id = b['id'].toString();
      final orders = await api.listOpenOrders(id);
      if (orders.isNotEmpty) {
        stdout.writeln('branch "${b['name']}" open orders: ${orders.length}');
        final o = orders.first;
        final products = (o['products'] as List?) ?? const [];
        final line = products.isNotEmpty ? products.first as Map : {};
        final prod = (line['product'] as Map?) ?? {};
        stdout.writeln('  sample order #${o['number']} status=${o['status']} '
            'lines=${products.length} hasCustomer=${o['customer'] != null}');
        stdout.writeln('  first line product: ${prod['name']} '
            '(id ${prod['id'].toString().substring(0, 8)}…) qty=${line['quantity']}');
        break;
      }
    }
    final products = await api.listProducts(maxPages: 2);
    stdout.writeln('products (2 pages): ${products.length}');
    stdout.writeln('OK — Dart FoodicsApi works against the live API.');
  } on FoodicsException catch (e) {
    stderr.writeln('FoodicsException: ${e.message}');
    exit(1);
  } finally {
    api.dispose();
  }
}
