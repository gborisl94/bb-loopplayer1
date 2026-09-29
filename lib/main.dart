import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const BBLoopApp());

class BBLoopApp extends StatelessWidget {
  const BBLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BB Loop Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
      ),
      home: const PlayerPage(),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;

  String? _path;
  String _name = 'Aucun fichier chargé';
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration? _a;
  Duration? _b;

  bool _loopOn = true;
  bool _infinite = false;
  int _repeats = 4;
  int _done = 0;
  double _speed = 1.0;

  bool _playing = false;
  bool _busy = false;
  bool _dragging = false;
  bool _seeking = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _posSub = _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 30),
          maxPeriod: const Duration(milliseconds: 60),
        )
        .listen(_onPos);
    _durSub = _player.durationStream.listen((d) {
      if (d != null && mounted) setState(() => _dur = d);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _playing =
            s.playing && s.processingState != ProcessingState.completed;
      });
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ---------- Boucle A-B ----------

  Future<void> _onPos(Duration p) async {
    if (!mounted) return;
    if (!_dragging) setState(() => _pos = p);

    final a = _a;
    final b = _b;
    if (_loopOn &&
        a != null &&
        b != null &&
        b > a &&
        !_seeking &&
        _player.playing &&
        p >= b) {
      _seeking = true;
      _done++;
      if (_infinite || _done < _repeats) {
        await _player.seek(a);
      } else {
        await _player.pause();
        await _player.seek(a);
        _done = 0;
        _status = 'Boucle terminée ($_repeats×)';
      }
      _seeking = false;
      if (mounted) setState(() {});
    }
  }

  void _setA() {
    final p = _player.position;
    setState(() {
      _a = p;
      if (_b != null && _b! <= p) _b = null;
      _done = 0;
    });
  }

  void _setB() {
    final p = _player.position;
    final a = _a;
    if (a != null && p <= a) {
      _msg('B doit être après A');
      return;
    }
    setState(() {
      _b = p;
      _done = 0;
    });
  }

  void _nudge(bool isA, int ms) {
    final cur = isA ? _a : _b;
    if (cur == null) return;
    var n = cur + Duration(milliseconds: ms);
    if (n < Duration.zero) n = Duration.zero;
    if (_dur > Duration.zero && n > _dur) n = _dur;
    if (isA && _b != null && n >= _b!) return;
    if (!isA && _a != null && n <= _a!) return;
    setState(() {
      if (isA) {
        _a = n;
      } else {
        _b = n;
      }
      _done = 0;
    });
  }

  // ---------- Fichier / lecture ----------

  Future<void> _pick() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.audio);
      if (r == null || r.files.single.path == null) return;
      final path = r.files.single.path!;
      await _player.stop();
      final d = await _player.setFilePath(path);
      await _player.setSpeed(_speed);
      setState(() {
        _path = path;
        _name = r.files.single.name;
        _dur = d ?? Duration.zero;
        _pos = Duration.zero;
        _a = null;
        _b = null;
        _done = 0;
        _status = '';
      });
    } catch (e) {
      _msg('Impossible de charger ce fichier : $e');
    }
  }

  Future<void> _togglePlay() async {
    if (_path == null) {
      _msg('Charge d\'abord un fichier audio');
      return;
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(_a ?? Duration.zero);
      }
      _status = '';
      _player.play();
    }
  }

  Future<void> _skip(int seconds) async {
    if (_path == null) return;
    var t = _player.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (_dur > Duration.zero && t > _dur) t = _dur;
    await _player.seek(t);
  }

  Future<void> _setSpeed(double v) async {
    setState(() => _speed = v);
    await _player.setSpeed(v);
  }

  // ---------- Génération du fichier ----------

  Future<void> _generate() async {
    final a = _a;
    final b = _b;
    final src = _path;
    if (src == null || a == null || b == null || b <= a) {
      _msg('Charge un fichier et définis A puis B');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Découpe en cours…';
    });

    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final cut = '${tmp.path}/bb_cut_$stamp.wav';
    final outTmp = '${tmp.path}/bb_out_$stamp.mp3';

    try {
      await [Permission.audio, Permission.storage].request();

      final startS = (a.inMilliseconds / 1000).toStringAsFixed(3);
      final durS = ((b - a).inMilliseconds / 1000).toStringAsFixed(3);
      final n = _repeats;

      final s1 = await FFmpegKit.executeWithArguments([
        '-y', '-i', src, '-ss', startS, '-t', durS,
        '-vn', '-c:a', 'pcm_s16le', cut,
      ]);
      if (!ReturnCode.isSuccess(await s1.getReturnCode())) {
        throw Exception('découpe impossible');
      }

      if (mounted) {
        setState(() => _status = n > 1
            ? 'Assemblage ($n×) et encodage MP3…'
            : 'Encodage MP3…');
      }

      final args = n > 1
          ? ['-y', '-stream_loop', '${n - 1}', '-i', cut,
             '-c:a', 'libmp3lame', '-q:a', '2', outTmp]
          : ['-y', '-i', cut, '-c:a', 'libmp3lame', '-q:a', '2', outTmp];
      final s2 = await FFmpegKit.executeWithArguments(args);
      if (!ReturnCode.isSuccess(await s2.getReturnCode())) {
        throw Exception('encodage impossible');
      }

      final base = _name
          .replaceAll(RegExp(r'\.[^.]+$'), '')
          .replaceAll(RegExp(r'[^\w\-]+'), '_');
      final fileName = 'BB_${base}_${n}x_$stamp.mp3';
      final saved = await _saveToMusic(outTmp, fileName);

      if (mounted) setState(() => _status = 'Fichier créé :\n$saved');
    } catch (e) {
      if (mounted) setState(() => _status = 'Erreur : $e');
    } finally {
      for (final f in [cut, outTmp]) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _saveToMusic(String tmpPath, String fileName) async {
    try {
      final dir = Directory('/storage/emulated/0/Music/BB Loops');
      await dir.create(recursive: true);
      final dest = '${dir.path}/$fileName';
      await File(tmpPath).copy(dest);
      return dest;
    } catch (_) {
      final ext = await getExternalStorageDirectory();
      final base = ext ?? await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/BB Loops');
      await dir.create(recursive: true);
      final dest = '${dir.path}/$fileName';
      await File(tmpPath).copy(dest);
      return dest;
    }
  }

  // ---------- UI ----------

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--.-';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final t = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s.$t' : '$m:$s.$t';
  }

  Widget _rangeBar() {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 6,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        final total = _dur.inMilliseconds;
        double f(Duration? d) =>
            (d == null || total == 0) ? 0.0 : (d.inMilliseconds / total).clamp(0.0, 1.0);
        final left = f(_a) * w;
        final right = _b == null ? left : f(_b) * w;
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            if (_a != null)
              Positioned(
                left: left,
                top: 0,
                bottom: 0,
                width: (right - left).clamp(3.0, w),
                child: Container(color: color),
              ),
          ],
        );
      }),
    );
  }

  Widget _abColumn(String label, Duration? value, bool isA) {
    return Expanded(
      child: Column(
        children: [
          FilledButton.tonal(
            onPressed: _path == null ? null : (isA ? _setA : _setB),
            child: Text('SET $label'),
          ),
          const SizedBox(height: 6),
          Text(_fmt(value),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '-0,1 s',
                onPressed: value == null ? null : () => _nudge(isA, -100),
                icon: const Icon(Icons.remove),
              ),
              IconButton(
                tooltip: '+0,1 s',
                onPressed: value == null ? null : () => _nudge(isA, 100),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = _dur.inMilliseconds > 0 ? _dur.inMilliseconds : 1;
    final val = _pos.inMilliseconds.clamp(0, maxMs).toDouble();
    final canGenerate = !_busy && _path != null && _a != null && _b != null;
    final shown = (_done + 1) > _repeats ? _repeats : (_done + 1);

    return Scaffold(
      appBar: AppBar(title: const Text('BB Loop Player')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.library_music),
                  title: Text(_name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: FilledButton(
                    onPressed: _busy ? null : _pick,
                    child: const Text('Charger'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _rangeBar(),
              Slider(
                value: val,
                max: maxMs.toDouble(),
                onChangeStart: (_) => _dragging = true,
                onChanged: (v) =>
                    setState(() => _pos = Duration(milliseconds: v.round())),
                onChangeEnd: (v) async {
                  _dragging = false;
                  await _player.seek(Duration(milliseconds: v.round()));
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text(_fmt(_pos)), Text(_fmt(_dur))],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 36,
                    onPressed: () => _skip(-5),
                    icon: const Icon(Icons.replay_5),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    iconSize: 44,
                    onPressed: _togglePlay,
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    iconSize: 36,
                    onPressed: () => _skip(5),
                    icon: const Icon(Icons.forward_5),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _abColumn('A', _a, true),
                  _abColumn('B', _b, false),
                ],
              ),
              const Divider(height: 32),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Boucle A → B'),
                value: _loopOn,
                onChanged: (v) => setState(() {
                  _loopOn = v;
                  _done = 0;
                }),
              ),
              Row(
                children: [
                  const Text('Répétitions'),
                  Expanded(
                    child: Slider(
                      value: _repeats.toDouble(),
                      min: 1,
                      max: 20,
                      divisions: 19,
                      label: '$_repeats×',
                      onChanged: (v) => setState(() {
                        _repeats = v.round();
                        _done = 0;
                      }),
                    ),
                  ),
                  Text('$_repeats×',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lecture infinie (sans limite)'),
                value: _infinite,
                onChanged: (v) => setState(() {
                  _infinite = v;
                  _done = 0;
                }),
              ),
              if (_loopOn && _a != null && _b != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _infinite
                        ? 'Boucle n°${_done + 1}'
                        : 'Boucle $shown / $_repeats',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [0.5, 0.75, 1.0, 1.25, 1.5].map((v) {
                  return ChoiceChip(
                    label: Text('${v}x'),
                    selected: _speed == v,
                    onSelected: (_) => _setSpeed(v),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: canGenerate ? _generate : null,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.audio_file),
                label: Text('GÉNÉRER FICHIER AUDIO ($_repeats×)'),
              ),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_status, textAlign: TextAlign.center),
                ),
            ],
          ),
        ),
      ),
    );
  }
}