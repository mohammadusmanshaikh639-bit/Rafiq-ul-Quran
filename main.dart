import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

// Run with: flutter run --dart-define=LLM_KEY=your_gemini_key
// For production, route calls through your own backend so the key never ships in the app.
const llmKey = String.fromEnvironment('LLM_KEY');
const llmModel = 'gemini-2.0-flash'; // change to any current Gemini model

const systemPrompt = '''
You are Rafiq-ul-Quran (رفیق القرآن), a personal Islamic companion and intellectual partner.
- Mirror the user's mood: gentle in grief or joy, sharp and analytical when examining facts.
- Be honest and bold. Judge claims by evidence, logic and moral reasoning, not by political narratives.
- When you state a historical or controversial fact, name your sources, and give links when asked.
- Never invent Quran verses, hadith or fiqh rulings. For religious texts, tell the user to check the Quran tab
  (verified API) and say clearly when you are unsure.
- Reply in the language the user writes in (Urdu, English or Arabic).
- Be a motivator and a curious partner, and play games when asked.
''';

void main() => runApp(const RafiqApp());

class RafiqApp extends StatelessWidget {
  const RafiqApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Rafiq-ul-Quran',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6E4F), useMaterial3: true),
        home: const Gate(),
      );
}

// ---------- Local database ----------
class Db {
  static Database? _d;
  static Future<Database> get db async => _d ??= await openDatabase(
        join(await getDatabasesPath(), 'rafiq.db'),
        version: 1,
        onCreate: (d, _) async {
          await d.execute('CREATE TABLE chat(id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT, text TEXT)');
          await d.execute(
              'CREATE TABLE log(day TEXT PRIMARY KEY, done TEXT, missed TEXT, quran TEXT, reflection TEXT)');
        },
      );
}

// ---------- Passcode lock ----------
class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  bool unlocked = false;
  @override
  Widget build(BuildContext context) =>
      unlocked ? const Home() : LockScreen(onOk: () => setState(() => unlocked = true));
}

class LockScreen extends StatefulWidget {
  final VoidCallback onOk;
  const LockScreen({super.key, required this.onOk});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final store = const FlutterSecureStorage();
  final ctrl = TextEditingController();
  String? saved;
  bool loading = true;
  String msg = '';

  @override
  void initState() {
    super.initState();
    store.read(key: 'pin_hash').then((v) => setState(() {
          saved = v;
          loading = false;
        }));
  }

  String hash(String p) => sha256.convert(utf8.encode('rafiq:$p')).toString();

  Future<void> submit() async {
    final pin = ctrl.text.trim();
    if (pin.length < 4) return setState(() => msg = 'Use at least 4 digits');
    if (saved == null) {
      await store.write(key: 'pin_hash', value: hash(pin));
      widget.onOk();
    } else if (saved == hash(pin)) {
      widget.onOk();
    } else {
      setState(() => msg = 'Wrong passcode');
      ctrl.clear();
    }
  }

  Future<void> biometric() async {
    try {
      final auth = LocalAuthentication();
      if (await auth.canCheckBiometrics &&
          await auth.authenticate(localizedReason: 'Unlock Rafiq-ul-Quran')) {
        widget.onOk();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('رفیق القرآن', style: TextStyle(fontSize: 34)),
          const SizedBox(height: 24),
          Text(saved == null ? 'Create your passcode' : 'Enter passcode'),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            onSubmitted: (_) => submit(),
          ),
          if (msg.isNotEmpty) Text(msg, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 12),
          FilledButton(onPressed: submit, child: Text(saved == null ? 'Save' : 'Unlock')),
          if (saved != null) TextButton(onPressed: biometric, child: const Text('Use biometrics')),
        ]),
      ),
    );
  }
}

// ---------- Home ----------
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    const pages = [ChatPage(), QuranPage(), TrackerPage()];
    return Scaffold(
      appBar: AppBar(title: const Text('Rafiq-ul-Quran')),
      body: pages[tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.menu_book_outlined), label: 'Quran'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), label: 'Tracker'),
        ],
      ),
    );
  }
}

// ---------- Chat ----------
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ctrl = TextEditingController();
  List<Map<String, Object?>> msgs = [];
  bool busy = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final d = await Db.db;
    final r = await d.query('chat', orderBy: 'id ASC');
    setState(() => msgs = r);
  }

  Future<void> add(String role, String text) async =>
      (await Db.db).insert('chat', {'role': role, 'text': text});

  Future<String> askLlm() async {
    final recent = msgs.length > 20 ? msgs.sublist(msgs.length - 20) : msgs;
    final res = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$llmModel:generateContent'),
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': llmKey},
      body: jsonEncode({
        'system_instruction': {
          'parts': [
            {'text': systemPrompt}
          ]
        },
        'contents': [
          for (final m in recent)
            {
              'role': m['role'] == 'user' ? 'user' : 'model',
              'parts': [
                {'text': m['text']}
              ]
            }
        ],
      }),
    );
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    return j['candidates'][0]['content']['parts'][0]['text'] as String;
  }

  Future<void> send() async {
    final t = ctrl.text.trim();
    if (t.isEmpty || busy) return;
    ctrl.clear();
    setState(() => busy = true);
    await add('user', t);
    await load();
    try {
      await add('model', await askLlm());
    } catch (e) {
      await add('model', 'Connection problem. Please try again.');
    }
    await load();
    setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: msgs.length,
            itemBuilder: (_, i) {
              final me = msgs[i]['role'] == 'user';
              return Align(
                alignment: me ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                  decoration: BoxDecoration(
                    color: me ? Theme.of(context).colorScheme.primaryContainer : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SelectableText(msgs[i]['text'] as String),
                ),
              );
            },
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: 'Message...', border: OutlineInputBorder()),
                ),
              ),
              IconButton(onPressed: send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]);
}

// ---------- Quran (verified API) ----------
class QuranPage extends StatefulWidget {
  const QuranPage({super.key});
  @override
  State<QuranPage> createState() => _QuranPageState();
}

class _QuranPageState extends State<QuranPage> {
  final ctrl = TextEditingController(text: '2:255');
  String arabic = '', english = '', error = '';

  Future<void> fetch() async {
    setState(() => error = '');
    try {
      final r = await http.get(Uri.parse(
          'https://api.alquran.cloud/v1/ayah/${ctrl.text.trim()}/editions/quran-uthmani,en.sahih'));
      final d = jsonDecode(utf8.decode(r.bodyBytes))['data'] as List;
      setState(() {
        arabic = d[0]['text'];
        english = d[1]['text'];
      });
    } catch (_) {
      setState(() => error = 'Could not load. Use format surah:ayah, e.g. 2:255');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'Surah:Ayah', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: fetch, child: const Text('Show')),
        ]),
        const SizedBox(height: 16),
        if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.red)),
        if (arabic.isNotEmpty) ...[
          Directionality(
            textDirection: TextDirection.rtl,
            child: Text(arabic, style: const TextStyle(fontSize: 26, height: 1.9)),
          ),
          const Divider(height: 32),
          Text(english, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          const Text('Source: api.alquran.cloud (Uthmani text, Sahih International)',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ]);
}

// ---------- Daily tracker ----------
class TrackerPage extends StatefulWidget {
  const TrackerPage({super.key});
  @override
  State<TrackerPage> createState() => _TrackerPageState();
}

class _TrackerPageState extends State<TrackerPage> {
  final done = TextEditingController(), missed = TextEditingController();
  final quran = TextEditingController(), reflect = TextEditingController();
  List<Map<String, Object?>> days = [];

  String get today => DateTime.now().toIso8601String().substring(0, 10);

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final d = await Db.db;
    days = await d.query('log', orderBy: 'day DESC', limit: 7);
    final t = days.where((e) => e['day'] == today);
    if (t.isNotEmpty) {
      done.text = t.first['done'] as String? ?? '';
      missed.text = t.first['missed'] as String? ?? '';
      quran.text = t.first['quran'] as String? ?? '';
      reflect.text = t.first['reflection'] as String? ?? '';
    }
    setState(() {});
  }

  Future<void> save() async {
    final d = await Db.db;
    await d.insert(
        'log',
        {
          'day': today,
          'done': done.text,
          'missed': missed.text,
          'quran': quran.text,
          'reflection': reflect.text
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  Widget field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          maxLines: 3,
          minLines: 1,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        Text('Today · $today', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        field(done, 'What I completed'),
        field(missed, 'What I missed'),
        field(quran, 'Quran reading / revision / mistakes'),
        field(reflect, 'Self-correction (arguments, biases, missteps)'),
        FilledButton(onPressed: save, child: const Text('Save today')),
        const Divider(height: 32),
        Text('Last 7 days', style: Theme.of(context).textTheme.titleMedium),
        for (final e in days)
          ListTile(
            title: Text(e['day'] as String),
            subtitle: Text('Done: ${e['done']}\nMissed: ${e['missed']}'),
            isThreeLine: true,
          ),
      ]);
}
