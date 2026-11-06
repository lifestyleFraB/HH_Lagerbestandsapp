import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:printing/printing.dart';
import 'package:flutter/foundation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://baatkchzwluaaxwyciep.supabase.co',
    publishableKey: 'sb_publishable_gdvPQ00Np4M9Yac4f680UQ_qdcdLaLz',
  );

  runApp(const LagerApp());
}

final supabase = Supabase.instance.client;

class LagerApp extends StatelessWidget {
  const LagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lagerverwaltung Komplett',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const ArtikelUebersichtPage(),
    );
  }
}

class ArtikelUebersichtPage extends StatefulWidget {
  const ArtikelUebersichtPage({super.key});

  @override
  State<ArtikelUebersichtPage> createState() => _ArtikelUebersichtPageState();
}

class _ArtikelUebersichtPageState extends State<ArtikelUebersichtPage> {
  var _artikelList = [];
  var _lagerorteList = [];
  bool _isLoading = true;
  bool _nurKritischeZeigen = false;
  String _searchQuery = '';
  String _einkaufEmail = 'frank.berndt@protonmail.com';
  String? _ausgewaehlterLagerort;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadData();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _einkaufEmail = prefs.getString('einkauf_email') ?? 'einkauf@firma.de';
    });
  }

  Future<void> _saveSettings(String newEmail) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('einkauf_email', newEmail);
    setState(() {
      _einkaufEmail = newEmail;
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final lagerorteData = await supabase
          .from('lagerorte')
          .select()
          .order('name');
      final artikelData = await supabase
          .from('artikel')
          .select('*, lagerorte(name)')
          .order('title');

      setState(() {
        _lagerorteList = List.from(lagerorteData);
        _artikelList = List.from(artikelData);
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Fehler beim Laden: $e')));
      }
      setState(() => _isLoading = false);
    }
  }

  List get _gefilterteArtikel {
    return _artikelList.where((artikel) {
      final title = (artikel['title'] ?? artikel['name'] ?? '')
          .toString()
          .toLowerCase();
      final matchesSearch = title.contains(_searchQuery.toLowerCase());

      final int bestand = artikel['bestand'] ?? 0;
      final int mindestbestand = artikel['mindestbestand'] ?? 0;
      final bool istKritisch = bestand <= mindestbestand;

      bool matchesLagerort = true;
      if (_ausgewaehlterLagerort != null) {
        final passenderOrt = _lagerorteList.firstWhere(
          (ort) =>
              (ort is Map && ort['name']?.toString() == _ausgewaehlterLagerort),
          orElse: () => null,
        );
        final gefundeneId = passenderOrt != null ? passenderOrt['id'] : null;

        final artikelLagerortId =
            artikel['lagerort_ID'] ?? artikel['lagerort_id'];
        matchesLagerort =
            (gefundeneId != null &&
            artikelLagerortId != null &&
            artikelLagerortId.toString() == gefundeneId.toString());
      }

      if (_nurKritischeZeigen) {
        return matchesSearch && istKritisch && matchesLagerort;
      }
      return matchesSearch && matchesLagerort;
    }).toList();
  }

  Future<void> _changeBestand(
    Map<String, dynamic> artikel,
    int neuerBestand, {
    String? kommentar,
  }) async {
    if (neuerBestand < 0) return;
    final String artikelId = artikel['id'];
    final int alterBestand = artikel['bestand'] ?? 0;
    final int aenderung = neuerBestand - alterBestand;

    if (aenderung == 0) return;

    try {
      await supabase
          .from('artikel')
          .update({'bestand': neuerBestand})
          .eq('id', artikelId);

      await supabase.from('bestands_historie').insert({
        'artikel_id': artikelId,
        'aenderung': aenderung,
        'bestand_alt': alterBestand,
        'bestand_neu': neuerBestand,
        'kommentar':
            kommentar ?? (aenderung > 0 ? 'Wareneingang' : 'Warenausgang'),
      });

      _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Fehler beim Buchen: $e')));
      }
    }
  }

  void _openLagerortDialog() {
    final nameController = TextEditingController();
    final beschreibungController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neuen Lagerort anlegen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Bezeichnung (z.B. Regal 3)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: beschreibungController,
              decoration: const InputDecoration(
                labelText: 'Beschreibung (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                try {
                  await supabase.from('lagerorte').insert({
                    'name': name,
                    'beschreibung':
                        beschreibungController.text.trim().isNotEmpty
                        ? beschreibungController.text.trim()
                        : null,
                  });
                  Navigator.pop(ctx);
                  _loadData();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Lagerort erfolgreich erstellt!'),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Fehler beim Erstellen: $e')),
                    );
                  }
                }
              }
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  // --- PDF / LAGERÜBERSICHT ALS DIREKT-DOWNLOAD (100% Web-sicher) ---
  Future<void> _druckeLagerUebersicht() async {
    try {
      final listToExport = _gefilterteArtikel;
      if (listToExport.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Keine Artikel für diesen Ausdruck vorhanden.'),
          ),
        );
        return;
      }

      String lagerTitel = _ausgewaehlterLagerort ?? 'Gesamtes Lager';
      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(32),
          build: (context) => [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Lagerübersicht',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Bereich: $lagerTitel',
                      style: const pw.TextStyle(
                        fontSize: 12,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),
                pw.Text(
                  'Datum: ${DateTime.now().toLocal().toString().substring(0, 10)}',
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 15),
            pw.Divider(thickness: 1, color: PdfColors.blue800),
            pw.SizedBox(height: 15),
            pw.Table.fromTextArray(
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 11,
              ),
              cellStyle: const pw.TextStyle(fontSize: 11),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.blue800,
              ),
              columnWidths: {
                0: const pw.FlexColumnWidth(3.0),
                1: const pw.FixedColumnWidth(70),
                2: const pw.FixedColumnWidth(90),
                3: const pw.FixedColumnWidth(80),
                4: const pw.FixedColumnWidth(60),
                5: const pw.FlexColumnWidth(2.0),
                6: const pw.FixedColumnWidth(70),
              },
              headers: [
                'Artikel',
                'Pakete',
                'Inhalt/Pkg',
                'Gesamt',
                'Min',
                'Lagerort',
                'Status',
              ],
              data: listToExport.map((item) {
                final int pakete = item['bestand'] ?? 0;
                final int inhalt = item['inhalt_pro_paket'] ?? 1;
                final int gesamt = pakete * inhalt;
                final int m = item['mindestbestand'] ?? 0;
                return [
                  item['title'] ?? '',
                  pakete.toString(),
                  inhalt.toString(),
                  gesamt.toString(),
                  m.toString(),
                  item['lagerorte']?['name'] ?? '-',
                  pakete <= m ? 'KRITISCH' : 'OK',
                ];
              }).toList(),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();
      final fileName = 'Lagerbestand_${lagerTitel.replaceAll(' ', '_')}.pdf';

      if (kIsWeb) {
        // Im Web direkt den Browser-Dialog zum Speichern/Drucken öffnen
        await Printing.layoutPdf(
          onLayout: (format) async => bytes,
          name: fileName,
        );
      } else {
        // Auf mobilen Geräten den Teilen-Dialog nutzen
        await Printing.sharePdf(bytes: bytes, filename: fileName);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PDF erfolgreich erstellt und heruntergeladen!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Fehler beim PDF-Export: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // --- EXPORT & EMAIL METHODEN (100% Web- & Mobil-sicher) ---
  Future<void> _exportAndSend({required bool isPdf}) async {
    final listToExport = _gefilterteArtikel;
    if (listToExport.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Keine Artikel zum Exportieren vorhanden.'),
        ),
      );
      return;
    }

    String lagerTitel = _ausgewaehlterLagerort ?? 'Gesamtes Lager';

    // 1. FÜR WEB: Direkt über Printing.layoutPdf ausgeben (umgeht dart:io, path_provider und email_sender komplett)
    if (kIsWeb) {
      await Printing.layoutPdf(
        name: 'Lagerbestand_${lagerTitel.replaceAll(' ', '_')}.pdf',
        onLayout: (PdfPageFormat format) async {
          final pdf = pw.Document();
          pdf.addPage(
            pw.MultiPage(
              pageFormat: format,
              margin: const pw.EdgeInsets.all(32),
              build: (context) => [
                pw.Header(
                  level: 0,
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Bestellliste / Nachbestellung',
                        style: pw.TextStyle(
                          fontSize: 22,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        'Datum: ${DateTime.now().toLocal().toString().substring(0, 10)}',
                        style: const pw.TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 20),
                pw.Table.fromTextArray(
                  headerStyle: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.white,
                  ),
                  headerDecoration: const pw.BoxDecoration(
                    color: PdfColors.blue800,
                  ),
                  headers: [
                    'Artikel',
                    'Pakete',
                    'Inhalt',
                    'Gesamt',
                    'Min',
                    'Lagerort',
                    'Status',
                  ],
                  data: listToExport.map((item) {
                    final int b = item['bestand'] ?? 0;
                    final int inhalt = item['inhalt_pro_paket'] ?? 1;
                    final int m = item['mindestbestand'] ?? 0;
                    return [
                      item['title'] ?? '',
                      b.toString(),
                      inhalt.toString(),
                      (b * inhalt).toString(),
                      m.toString(),
                      item['lagerorte']?['name'] ?? '-',
                      b <= m ? 'KRITISCH' : 'OK',
                    ];
                  }).toList(),
                ),
              ],
            ),
          );
          return pdf.save();
        },
      );
      return;
    }

    // 2. FÜR MOBILGERÄTE (Android / iOS):
    try {
      final output = await getTemporaryDirectory();
      File file;

      if (isPdf) {
        final pdf = pw.Document();
        pdf.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(32),
            build: (context) => [
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Bestellliste / Nachbestellung',
                      style: pw.TextStyle(
                        fontSize: 22,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      'Datum: ${DateTime.now().toLocal().toString().substring(0, 10)}',
                      style: const pw.TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Table.fromTextArray(
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                ),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.blue800,
                ),
                headers: [
                  'Artikel',
                  'Pakete',
                  'Inhalt',
                  'Gesamt',
                  'Min',
                  'Lagerort',
                  'Status',
                ],
                data: listToExport.map((item) {
                  final int b = item['bestand'] ?? 0;
                  final int inhalt = item['inhalt_pro_paket'] ?? 1;
                  final int m = item['mindestbestand'] ?? 0;
                  return [
                    item['title'] ?? '',
                    b.toString(),
                    inhalt.toString(),
                    (b * inhalt).toString(),
                    m.toString(),
                    item['lagerorte']?['name'] ?? '-',
                    b <= m ? 'KRITISCH' : 'OK',
                  ];
                }).toList(),
              ),
            ],
          ),
        );
        file = File(
          '${output.path}/lagerbestand_${DateTime.now().millisecondsSinceEpoch}.pdf',
        );
        await file.writeAsBytes(await pdf.save());
      } else {
        List<List<dynamic>> rows = [
          [
            'Titel',
            'Pakete',
            'Inhalt_pro_Paket',
            'Gesamtmenge',
            'Mindestbestand',
            'Lagerort',
            'Barcode',
            'Status',
          ],
        ];
        for (var item in listToExport) {
          final int b = item['bestand'] ?? 0;
          final int inhalt = item['inhalt_pro_paket'] ?? 1;
          final int m = item['mindestbestand'] ?? 0;
          rows.add([
            item['title'] ?? '',
            b,
            inhalt,
            b * inhalt,
            m,
            item['lagerorte']?['name'] ?? '',
            item['barcode'] ?? '',
            b <= m ? 'KRITISCH' : 'OK',
          ]);
        }
        String csvData = const ListToCsvConverter().convert(rows);
        file = File(
          '${output.path}/lagerbestand_${DateTime.now().millisecondsSinceEpoch}.csv',
        );
        await file.writeAsString(csvData);
      }

      final Email email = Email(
        body:
            'Hallo Thomas,\n\nanbei befindet sich die aktuelle Bestandsliste (${isPdf ? "PDF" : "CSV"}).\n\nViele Grüße',
        subject:
            'Nachbestellung / Bestandsliste (${isPdf ? "PDF" : "CSV"}) - ${DateTime.now().toString().substring(0, 10)}',
        recipients: [_einkaufEmail],
        attachmentPaths: [file.path],
        isHTML: false,
      );

      try {
        await FlutterEmailSender.send(email);
      } catch (e) {
        await Share.shareXFiles([XFile(file.path)], text: 'Lagerbestandsliste');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fehler beim Export: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _openSettingsDialog() {
    final controller = TextEditingController(text: _einkaufEmail);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Einkauf E-Mail konfigurieren'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'E-Mail-Adresse für Bestellungen',
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                _saveSettings(controller.text.trim());
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('E-Mail-Adresse gespeichert.')),
                );
              }
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  void _openArtikelForm({Map<String, dynamic>? artikel, bool isCopy = false}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ArtikelFormModal(
        artikel: artikel,
        isCopy: isCopy,
        lagerorte: _lagerorteList,
        onSaved: _loadData,
      ),
    );
  }

  void _openHistorieModal(Map<String, dynamic> artikel) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => HistorieModal(artikel: artikel),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kritischeAnzahl = _artikelList
        .where((a) => (a['bestand'] as int) <= (a['mindestbestand'] as int))
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Lager / Auswahl als PDF drucken',
            onPressed: _druckeLagerUebersicht,
          ),
          IconButton(
            icon: const Icon(Icons.add_location_alt),
            tooltip: 'Neuen Lagerort anlegen',
            onPressed: _openLagerortDialog,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Einkauf E-Mail einstellen',
            onPressed: _openSettingsDialog,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadData),
          PopupMenuButton<String>(
            icon: const Icon(Icons.share),
            onSelected: (val) {
              if (val == 'pdf') _exportAndSend(isPdf: true);
              if (val == 'csv') _exportAndSend(isPdf: false);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'pdf',
                child: Text('Als PDF an Einkauf senden'),
              ),
              const PopupMenuItem(
                value: 'csv',
                child: Text('Als CSV an Einkauf senden'),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 12.0,
                  ),
                  color: const Color(0xFFD3D3D3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset('assets/logo.png', height: 55),
                      const SizedBox(width: 12),
                      const Text(
                        'Lager',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Artikel suchen...',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (val) => setState(() => _searchQuery = val),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String?>(
                        value: _ausgewaehlterLagerort,
                        decoration: const InputDecoration(
                          labelText: 'Nach Lagerort filtern',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Alle Lagerorte anzeigen'),
                          ),
                          ..._lagerorteList.map((ort) {
                            final String ortsName = (ort is Map)
                                ? (ort['name']?.toString() ??
                                      ort['lagerorte']?.toString() ??
                                      '')
                                : ort.toString();
                            return DropdownMenuItem<String?>(
                              value: ortsName,
                              child: Text(ortsName),
                            );
                          }),
                        ],
                        onChanged: (val) {
                          setState(() {
                            _ausgewaehlterLagerort = val;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      FilterChip(
                        selected: _nurKritischeZeigen,
                        label: Text('Nur Nachzubestellende ($kritischeAnzahl)'),
                        avatar: const Icon(Icons.warning_amber),
                        onSelected: (bool value) {
                          setState(() {
                            _nurKritischeZeigen = value;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _gefilterteArtikel.isEmpty
                      ? const Center(child: Text('Keine Artikel gefunden.'))
                      : ListView.builder(
                          itemCount: _gefilterteArtikel.length,
                          itemBuilder: (ctx, index) {
                            final item = _gefilterteArtikel[index];
                            final int pakete = item['bestand'] ?? 0;
                            final int inhaltProPaket =
                                item['inhalt_pro_paket'] ?? 1;
                            final int gesamtMenge = pakete * inhaltProPaket;
                            final int mindestbestand =
                                item['mindestbestand'] ?? 0;
                            final bool istWarnung = pakete <= mindestbestand;
                            final String lagerortName =
                                item['lagerorte']?['name'] ?? 'Kein Lagerort';

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              color: istWarnung ? Colors.red.shade50 : null,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: istWarnung
                                          ? Colors.red.shade100
                                          : Colors.green.shade100,
                                      child: Icon(
                                        istWarnung
                                            ? Icons.warning
                                            : Icons.check_circle,
                                        color: istWarnung
                                            ? Colors.red
                                            : Colors.green,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item['title'] ?? '',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Lagerort: $lagerortName\nPakete: $pakete | Inhalt: $inhaltProPaket Stk. ➔ Gesamt: $gesamtMenge Stk.',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          icon: const Icon(
                                            Icons.history,
                                            size: 20,
                                            color: Colors.grey,
                                          ),
                                          onPressed: () =>
                                              _openHistorieModal(item),
                                          tooltip: 'Historie',
                                        ),
                                        IconButton(
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          icon: const Icon(
                                            Icons.copy,
                                            size: 18,
                                            color: Colors.orange,
                                          ),
                                          onPressed: () => _openArtikelForm(
                                            artikel: item,
                                            isCopy: true,
                                          ),
                                          tooltip: 'Artikel kopieren',
                                        ),
                                        IconButton(
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                            size: 22,
                                          ),
                                          onPressed: () =>
                                              _changeBestand(item, pakete - 1),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          child: Text(
                                            '$pakete Pkg',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: istWarnung
                                                  ? Colors.red
                                                  : Colors.black,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          icon: const Icon(
                                            Icons.add_circle_outline,
                                            size: 22,
                                          ),
                                          onPressed: () =>
                                              _changeBestand(item, pakete + 1),
                                        ),
                                        IconButton(
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          icon: const Icon(
                                            Icons.edit,
                                            size: 20,
                                            color: Colors.blue,
                                          ),
                                          onPressed: () =>
                                              _openArtikelForm(artikel: item),
                                          tooltip: 'Bearbeiten',
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openArtikelForm(),
        icon: const Icon(Icons.add),
        label: const Text('Neuer Artikel'),
      ),
    );
  }
}

class ArtikelFormModal extends StatefulWidget {
  final Map<String, dynamic>? artikel;
  final bool isCopy;
  final List lagerorte;
  final VoidCallback onSaved;

  const ArtikelFormModal({
    super.key,
    this.artikel,
    this.isCopy = false,
    required this.lagerorte,
    required this.onSaved,
  });

  @override
  State<ArtikelFormModal> createState() => _ArtikelFormModalState();
}

class _ArtikelFormModalState extends State<ArtikelFormModal> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _titleController;
  late TextEditingController _bestandController;
  late TextEditingController _inhaltController;
  late TextEditingController _mindestbestandController;
  late TextEditingController _barcodeController;
  String? _selectedLagerortId;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final a = widget.artikel;
    _titleController = TextEditingController(
      text: widget.isCopy
          ? '${a?['title'] ?? ''} (Kopie)'
          : (a?['title'] ?? ''),
    );
    _bestandController = TextEditingController(
      text: (a?['bestand'] ?? 0).toString(),
    );
    _inhaltController = TextEditingController(
      text: (a?['inhalt_pro_paket'] ?? 1).toString(),
    );
    _mindestbestandController = TextEditingController(
      text: (a?['mindestbestand'] ?? 0).toString(),
    );
    _barcodeController = TextEditingController(
      text: widget.isCopy ? '' : (a?['barcode'] ?? ''),
    );
    _selectedLagerortId = a?['lagerort_id'];
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final String title = _titleController.text.trim();
    final int neuerBestand = int.parse(_bestandController.text);
    final int inhaltProPaket = int.parse(_inhaltController.text);
    final int mindestbestand = int.parse(_mindestbestandController.text);
    final String barcode = _barcodeController.text.trim();

    try {
      if (widget.artikel == null || widget.isCopy) {
        final response = await supabase
            .from('artikel')
            .insert({
              'title': title,
              'bestand': neuerBestand,
              'inhalt_pro_paket': inhaltProPaket,
              'mindestbestand': mindestbestand,
              'barcode': barcode.isNotEmpty ? barcode : null,
              'lagerort_id': _selectedLagerortId,
            })
            .select()
            .single();

        await supabase.from('bestands_historie').insert({
          'artikel_id': response['id'],
          'aenderung': neuerBestand,
          'bestand_alt': 0,
          'bestand_neu': neuerBestand,
          'kommentar': widget.isCopy
              ? 'Artikel kopiert und neu angelegt'
              : 'Neuanlage des Artikels',
        });
      } else {
        final String artikelId = widget.artikel!['id'];
        final int alterBestand = widget.artikel!['bestand'] ?? 0;

        await supabase
            .from('artikel')
            .update({
              'title': title,
              'bestand': neuerBestand,
              'inhalt_pro_paket': inhaltProPaket,
              'mindestbestand': mindestbestand,
              'barcode': barcode.isNotEmpty ? barcode : null,
              'lagerort_id': _selectedLagerortId,
            })
            .eq('id', artikelId);

        if (alterBestand != neuerBestand) {
          await supabase.from('bestands_historie').insert({
            'artikel_id': artikelId,
            'aenderung': neuerBestand - alterBestand,
            'bestand_alt': alterBestand,
            'bestand_neu': neuerBestand,
            'kommentar': 'Bestandsänderung bei Bearbeitung',
          });
        }
      }

      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Speichern fehlgeschlagen: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.artikel != null && !widget.isCopy;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        top: 16,
        left: 16,
        right: 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.isCopy
                    ? 'Artikel kopieren'
                    : (isEdit ? 'Artikel bearbeiten' : 'Neuen Artikel anlegen'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Artikelbezeichnung',
                  border: OutlineInputBorder(),
                ),
                validator: (val) =>
                    val == null || val.isEmpty ? 'Titel eingeben' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _bestandController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Anzahl Pakete',
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) =>
                          val == null || val.isEmpty ? 'Menge' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _inhaltController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Inhalt pro Paket',
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) =>
                          val == null || val.isEmpty ? 'Inhalt' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _mindestbestandController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Mindestbestand (Pakete)',
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) =>
                          val == null || val.isEmpty ? 'Schwelle' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selectedLagerortId,
                decoration: const InputDecoration(
                  labelText: 'Lagerort auswählen',
                  border: OutlineInputBorder(),
                ),
                items: widget.lagerorte.map((ort) {
                  return DropdownMenuItem<String>(
                    value: ort['id'] as String,
                    child: Text(ort['name'] as String),
                  );
                }).toList(),
                onChanged: (val) => setState(() => _selectedLagerortId = val),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _barcodeController,
                decoration: const InputDecoration(
                  labelText: 'Barcode / EAN (Optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_isSaving ? 'Speichert...' : 'Speichern'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HistorieModal extends StatefulWidget {
  final Map<String, dynamic> artikel;

  const HistorieModal({super.key, required this.artikel});

  @override
  State<HistorieModal> createState() => _HistorieModalState();
}

class _HistorieModalState extends State<HistorieModal> {
  List _historieList = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistorie();
  }

  Future<void> _loadHistorie() async {
    try {
      final data = await supabase
          .from('bestands_historie')
          .select()
          .eq('artikel_id', widget.artikel['id'])
          .order('created_at', ascending: false);

      setState(() {
        _historieList = List.from(data);
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Historie: ${widget.artikel['title']}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Divider(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _historieList.isEmpty
                ? const Center(child: Text('Keine Historie vorhanden.'))
                : ListView.builder(
                    itemCount: _historieList.length,
                    itemBuilder: (ctx, index) {
                      final h = _historieList[index];
                      final int aenderung = h['aenderung'] ?? 0;
                      final String vorzeichen = aenderung > 0
                          ? '+$aenderung'
                          : '$aenderung';
                      final color = aenderung > 0 ? Colors.green : Colors.red;

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withOpacity(0.1),
                          child: Text(
                            vorzeichen,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(h['kommentar'] ?? 'Änderung'),
                        subtitle: Text(
                          'Alt: ${h['bestand_alt']} ➔ Neu: ${h['bestand_neu']}',
                        ),
                        trailing: Text(
                          h['created_at']
                              .toString()
                              .substring(0, 16)
                              .replaceFirst('T', ' '),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
