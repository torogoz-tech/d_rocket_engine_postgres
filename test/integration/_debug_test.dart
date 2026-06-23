import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:postgres/postgres.dart';

void main() async {
  final url = 'postgres://ai_user:'
      'Ep8y4iR92Gj06q4m5AtbM9Dff9DWnOwMbEjTqDFBPKg%3D'
      '@localhost:5433/ai_knowledge?sslmode=disable';
  print('Trying Connection.openFromUrl with sslmode=disable...');
  try {
    final c = await Connection.openFromUrl(url);
    print('OK. Closing.');
    await c.close();
  } on Object catch (e) {
    print('Connection.openFromUrl FAILED: $e');
  }

  print('Trying PostgresPool.open with the same URL...');
  try {
    final pool = await PostgresPool.open(
      url: url,
      config: PoolConfig(min: 1, max: 2),
    );
    print('Pool open OK.');
    await pool.disposeAsync();
  } on Object catch (e, st) {
    print('Pool FAILED: $e');
    print(st);
  }
}