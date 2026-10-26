import 'dart:convert';
import 'dart:io';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signature/signature.dart';

const rcKeyAndroid = 'YOUR_REVENUECAT_ANDROID_KEY';
const rcKeyIos = 'YOUR_REVENUECAT_IOS_KEY';
const entitlementId = 'pro';
const freeOcrPerMonth = 10;

final isPro = ValueNotifier<bool>(false);

// ---------- Model ----------
class Receipt {
  String merchant, date, currency, pdfPath;
  double total;
  List<String> pages;
  Receipt(this.merchant, this.date, this.total, this.currency, this.pdfPath, this.pages);
  Map<String, dynamic> toJson() => {'m': merchant, 'd': date, 't': total, 'c': currency, 'p': pdfPath, 'g': pages};
  factory Receipt.fromJson(Map<String, dynamic> j) =>
      Receipt(j['m'], j['d'], (j['t'] as num).toDouble(), j['c'], j['p'], List<String>.from(j['g']));
}

// ---------- Receipt parsing (rules based, runs on device) ----------
double _num(String s) =>
    double.parse(s.replaceAll(RegExp(r'[.,](?=\d{3}\b)'), '').replaceAll(',', '.'));

Receipt parseReceipt(String text, String pdf, List<String> pages) {
  final lines = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final amt = RegExp(r'\d{1,3}(?:[.,]\d{3})*[.,]\d{2}');
  double? best, anyMax;
  for (final l in lines) {
    for (final m in amt.allMatches(l)) {
      final v = _num(m.group(0)!);
      if (anyMax == null || v > anyMax) anyMax = v;
      if (RegExp(r'total', caseSensitive: false).hasMatch(l) &&
          !RegExp(r'sub', caseSensitive: false).hasMatch(l) &&
          (best == null || v > best)) best = v;
    }
  }
  final date = RegExp(r'\b\d{1,4}[/.-]\d{1,2}[/.-]\d{1,4}\b').firstMatch(text)?.group(0) ?? '';
  final cur = text.contains('€') ? 'EUR' : text.contains('£') ? 'GBP'
      : text.contains('₹') ? 'INR' : text.contains(RegExp(r'Rs\.?|PKR')) ? 'PKR'
      : text.contains(r'$') ? 'USD' : '';
  return Receipt(lines.isEmpty ? 'Unknown' : lines.first, date, best ?? anyMax ?? 0, cur, pdf, pages);
}

// ---------- Storage and limits ----------
class Store {
  static Future<File> _f() async => File('${(await getApplicationDocumentsDirectory()).path}/receipts.json');
  static Future<List<Receipt>> load() async {
    final f = await _f();
    if (!await f.exists()) return [];
    return (jsonDecode(await f.readAsString()) as List).map((e) => Receipt.fromJson(e)).toList();
  }
  static Future<void> save(List<Receipt> r) async =>
      (await _f()).writeAsString(jsonEncode(r.map((e) => e.toJson()).toList()));
  static String _key() { final n = DateTime.now(); return 'ocr_${n.year}_${n.month}'; }
  static Future<bool> canOcr() async =>
      isPro.value || ((await SharedPreferences.getInstance()).getInt(_key()) ?? 0) < freeOcrPerMonth;
  static Future<void> countOcr() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_key(), (p.getInt(_key()) ?? 0) + 1);
  }
}

// ---------- PDF ----------
Future<String> buildPdf(List<String> pages, {Uint8List? signature}) async {
  final doc = pw.Document();
  for (var i = 0; i < pages.length; i++) {
    final img = pw.MemoryImage(File(pages[i]).readAsBytesSync());
    final last = i == pages.length - 1;
    doc.addPage(pw.Page(build: (_) => pw.Stack(children: [
          pw.Center(child: pw.Image(img)),
          if (signature != null && last)
            pw.Positioned(right: 20, bottom: 20,
                child: pw.Image(pw.MemoryImage(signature), width: 120)),
        ])));
  }
  final dir = await getApplicationDocumentsDirectory();
  final out = File('${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await out.writeAsBytes(await doc.save());
  return out.path;
}

// ---------- Purchases ----------
Future<void> initPurchases() async {
  final key = Platform.isIOS ? rcKeyIos : rcKeyAndroid;
  if (key.startsWith('YOUR_')) return; // not configured yet
  await Purchases.configure(PurchasesConfiguration(key));
  await refreshPro();
}
Future<void> refreshPro() async {
  try {
    final info = await Purchases.getCustomerInfo();
    isPro.value = info.entitlements.active.containsKey(entitlementId);
  } catch (_) {}
}
Future<void> showPaywall(BuildContext c) async {
  await showModalBottomSheet(context: c, builder: (ctx) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('ScanPal Pro', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('Unlimited receipt OCR, CSV export, PDF signing. Cancel anytime in your store settings.',
          textAlign: TextAlign.center),
      const SizedBox(height: 16),
      FilledButton(onPressed: () async {
        try {
          final o = await Purchases.getOfferings();
          final p = o.current?.annual ?? o.current?.availablePackages.first;
          if (p != null) await Purchases.purchase(PurchaseParams.package(p));
          await refreshPro();
        } catch (_) {}
        if (ctx.mounted) Navigator.pop(ctx);
      }, child: const Text('Start free trial')),
      TextButton(onPressed: () async {
        try { await Purchases.restorePurchases(); await refreshPro(); } catch (_) {}
      }, child: const Text('Restore purchases')),
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Not now')),
    ]),
  ));
}

// ---------- UI ----------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initPurchases();
  runApp(const MaterialApp(home: Home(), debugShowCheckedModeBanner: false));
}

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _HomeState(); }
class _HomeState extends State<Home> {
  List<Receipt> items = [];
  bool busy = false;
  @override void initState() { super.initState(); Store.load().then((v) => setState(() => items = v)); }

  Future<void> scan() async {
    final pics = await CunningDocumentScanner.getPictures();
    if (pics == null || pics.isEmpty) return;
    setState(() => busy = true);
    final pdf = await buildPdf(pics);
    var r = Receipt('Document', '', 0, '', pdf, pics);
    if (await Store.canOcr()) {
      final rec = TextRecognizer();
      final res = await rec.processImage(InputImage.fromFilePath(pics.first));
      await rec.close();
      r = parseReceipt(res.text, pdf, pics);
      await Store.countOcr();
    } else if (mounted) { showPaywall(context); }
    items.insert(0, r);
    await Store.save(items);
    if (mounted) setState(() => busy = false);
  }

  Future<void> exportCsv() async {
    if (!isPro.value) return showPaywall(context);
    final b = StringBuffer('merchant,date,total,currency\n');
    for (final r in items) { b.writeln('"${r.merchant.replaceAll('"', '""')}",${r.date},${r.total},${r.currency}'); }
    final f = File('${(await getTemporaryDirectory()).path}/receipts.csv')..writeAsStringSync(b.toString());
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  @override Widget build(BuildContext c) => ValueListenableBuilder<bool>(
    valueListenable: isPro,
    builder: (_, pro, __) => Scaffold(
      appBar: AppBar(title: Text(pro ? 'ScanPal Pro' : 'ScanPal'), actions: [
        if (kDebugMode) Switch(value: pro, onChanged: (v) => isPro.value = v), // debug only
        IconButton(icon: const Icon(Icons.table_chart), tooltip: 'Export CSV', onPressed: exportCsv),
      ]),
      body: busy ? const Center(child: CircularProgressIndicator()) : ListView(children: [
        for (final r in items) ListTile(
          title: Text(r.merchant), subtitle: Text('${r.date}  ${r.currency} ${r.total.toStringAsFixed(2)}'),
          trailing: IconButton(icon: const Icon(Icons.draw), tooltip: 'Sign',
              onPressed: () => sign(r)),
          onTap: () => SharePlus.instance.share(ShareParams(files: [XFile(r.pdfPath)])),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: scan, icon: const Icon(Icons.document_scanner), label: const Text('Scan')),
    ));

  Future<void> sign(Receipt r) async {
    if (!isPro.value) return showPaywall(context);
    final ctl = SignatureController(penStrokeWidth: 3);
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Draw your signature'),
      content: SizedBox(height: 160, width: 300, child: Signature(controller: ctl, backgroundColor: Colors.grey.shade200)),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply'))]));
    final png = ok == true ? await ctl.toPngBytes() : null;
    if (png == null) return;
    r.pdfPath = await buildPdf(r.pages, signature: png);
    await Store.save(items);
    if (mounted) { setState(() {}); SharePlus.instance.share(ShareParams(files: [XFile(r.pdfPath)])); }
  }
}
