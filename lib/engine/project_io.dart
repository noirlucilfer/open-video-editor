/// Project save/load: JSON serialization plus a media bundle on disk.
///
/// A saved project lives in `<app-documents>/ove_projects/<name>/`:
/// `project.json` plus a `media/` folder holding copies of every referenced
/// media file, so the project still opens after the OS purges the picker
/// cache the original paths pointed at. Paths inside project.json always
/// point at the bundle copies.
///
/// Web is not supported (picked media lives at blob URLs that die on reload).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'video_engine.dart';

/// Format version written into every project.json.
const projectFormatVersion = 1;

Duration _dur(Map<String, dynamic> j, String key) =>
    Duration(milliseconds: (j[key] as num).toInt());

T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

Map<String, dynamic> _mediaSourceToJson(MediaSource s) => {
      'id': s.id,
      'path': s.path,
      'durationMs': s.duration.inMilliseconds,
      'hasVideo': s.hasVideo,
      'hasAudio': s.hasAudio,
    };

MediaSource _mediaSourceFromJson(Map<String, dynamic> j) => MediaSource(
      id: j['id'] as String,
      path: j['path'] as String,
      duration: _dur(j, 'durationMs'),
      hasVideo: j['hasVideo'] as bool? ?? true,
      hasAudio: j['hasAudio'] as bool? ?? true,
    );

Map<String, dynamic> _chromaKeyToJson(ChromaKey c) => {
      'enabled': c.enabled,
      'color': c.color,
      'similarity': c.similarity,
      'blend': c.blend,
      'bgColor': c.bgColor,
    };

ChromaKey _chromaKeyFromJson(Map<String, dynamic> j) => ChromaKey(
      enabled: j['enabled'] as bool? ?? false,
      color: (j['color'] as num?)?.toInt() ?? 0x00FF00,
      similarity: (j['similarity'] as num?)?.toDouble() ?? 0.3,
      blend: (j['blend'] as num?)?.toDouble() ?? 0.1,
      bgColor: (j['bgColor'] as num?)?.toInt() ?? 0x000000,
    );

Map<String, dynamic> _transitionToJson(ClipTransition t) => {
      'type': t.type.name,
      'durationMs': t.duration.inMilliseconds,
      'xfadeKind': t.xfadeKind.name,
    };

ClipTransition _transitionFromJson(Map<String, dynamic> j) => ClipTransition(
      type: _enumByName(TransitionType.values, j['type'] as String?,
          TransitionType.none),
      duration: _dur(j, 'durationMs'),
      xfadeKind: _enumByName(
          XfadeKind.values, j['xfadeKind'] as String?, XfadeKind.dissolve),
    );

Map<String, dynamic> _clipToJson(Clip c, Map<String, String> pathMap) => {
      'id': c.id,
      'source': _mediaSourceToJson(MediaSource(
        id: c.source.id,
        path: pathMap[c.source.path] ?? c.source.path,
        duration: c.source.duration,
        hasVideo: c.source.hasVideo,
        hasAudio: c.source.hasAudio,
      )),
      'timelineStartMs': c.timelineStart.inMilliseconds,
      'sourceStartMs': c.sourceStart.inMilliseconds,
      'durationMs': c.duration.inMilliseconds,
      'speed': c.speed,
      'filter': c.filter.name,
      'transitionIn': _transitionToJson(c.transitionIn),
      'transitionOut': _transitionToJson(c.transitionOut),
      'chromaKey': _chromaKeyToJson(c.chromaKey),
    };

Clip _clipFromJson(Map<String, dynamic> j) => Clip(
      id: j['id'] as String,
      source: _mediaSourceFromJson(j['source'] as Map<String, dynamic>),
      timelineStart: _dur(j, 'timelineStartMs'),
      sourceStart: _dur(j, 'sourceStartMs'),
      duration: _dur(j, 'durationMs'),
      speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
      filter: _enumByName(
          VideoFilter.values, j['filter'] as String?, VideoFilter.none),
      transitionIn: _transitionFromJson(
          j['transitionIn'] as Map<String, dynamic>? ?? {}),
      transitionOut: _transitionFromJson(
          j['transitionOut'] as Map<String, dynamic>? ?? {}),
      chromaKey: _chromaKeyFromJson(
          j['chromaKey'] as Map<String, dynamic>? ?? {}),
    );

Map<String, dynamic> _textOverlayToJson(TextOverlay o) => {
      'id': o.id,
      'text': o.text,
      'startMs': o.start.inMilliseconds,
      'endMs': o.end.inMilliseconds,
      'fontSize': o.fontSize,
      'x': o.x,
      'y': o.y,
      'keyframes': [
        for (final k in o.keyframes)
          {
            'timeMs': k.time.inMilliseconds,
            'x': k.x,
            'y': k.y,
            'fontSize': k.fontSize,
          }
      ],
    };

TextOverlay _textOverlayFromJson(Map<String, dynamic> j) => TextOverlay(
      id: j['id'] as String,
      text: j['text'] as String,
      start: _dur(j, 'startMs'),
      end: _dur(j, 'endMs'),
      fontSize: (j['fontSize'] as num?)?.toDouble() ?? 32,
      x: (j['x'] as num?)?.toDouble() ?? 0.5,
      y: (j['y'] as num?)?.toDouble() ?? 0.5,
      keyframes: [
        for (final k in (j['keyframes'] as List? ?? []))
          TextKeyframe(
            time: _dur(k as Map<String, dynamic>, 'timeMs'),
            x: (k['x'] as num).toDouble(),
            y: (k['y'] as num).toDouble(),
            fontSize: (k['fontSize'] as num).toDouble(),
          )
      ],
    );

Map<String, dynamic> _stickerToJson(
        StickerOverlay s, Map<String, String> pathMap) =>
    {
      'id': s.id,
      'path': pathMap[s.path] ?? s.path,
      'name': s.name,
      'startMs': s.start.inMilliseconds,
      'endMs': s.end.inMilliseconds,
      'x': s.x,
      'y': s.y,
      'scale': s.scale,
      'keyframes': [
        for (final k in s.keyframes)
          {
            'timeMs': k.time.inMilliseconds,
            'x': k.x,
            'y': k.y,
            'scale': k.scale,
          }
      ],
    };

StickerOverlay _stickerFromJson(Map<String, dynamic> j) => StickerOverlay(
      id: j['id'] as String,
      path: j['path'] as String,
      name: j['name'] as String? ?? '',
      start: _dur(j, 'startMs'),
      end: _dur(j, 'endMs'),
      x: (j['x'] as num?)?.toDouble() ?? 0.5,
      y: (j['y'] as num?)?.toDouble() ?? 0.5,
      scale: (j['scale'] as num?)?.toDouble() ?? 1.0,
      keyframes: [
        for (final k in (j['keyframes'] as List? ?? []))
          StickerKeyframe(
            time: _dur(k as Map<String, dynamic>, 'timeMs'),
            x: (k['x'] as num).toDouble(),
            y: (k['y'] as num).toDouble(),
            scale: (k['scale'] as num?)?.toDouble() ?? 1.0,
          )
      ],
    );

Map<String, dynamic> _audioTrackToJson(
        AudioTrack t, Map<String, String> pathMap) =>
    {
      'id': t.id,
      'path': pathMap[t.path] ?? t.path,
      'name': t.name,
      'timelineStartMs': t.timelineStart.inMilliseconds,
      'trimStartMs': t.trimStart.inMilliseconds,
      'durationMs': t.duration.inMilliseconds,
      'sourceDurationMs': t.sourceDuration.inMilliseconds,
      'volume': t.volume,
      'fadeInMs': t.fadeIn.inMilliseconds,
      'fadeOutMs': t.fadeOut.inMilliseconds,
    };

AudioTrack _audioTrackFromJson(Map<String, dynamic> j) => AudioTrack(
      id: j['id'] as String,
      path: j['path'] as String,
      name: j['name'] as String? ?? '',
      timelineStart: _dur(j, 'timelineStartMs'),
      trimStart: _dur(j, 'trimStartMs'),
      duration: _dur(j, 'durationMs'),
      sourceDuration: _dur(j, 'sourceDurationMs'),
      volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
      fadeIn: _dur(j, 'fadeInMs'),
      fadeOut: _dur(j, 'fadeOutMs'),
    );

Map<String, dynamic> _videoOverlayToJson(
        VideoOverlay o, Map<String, String> pathMap) =>
    {
      'id': o.id,
      'path': pathMap[o.path] ?? o.path,
      'name': o.name,
      'startMs': o.start.inMilliseconds,
      'endMs': o.end.inMilliseconds,
      'sourceStartMs': o.sourceStart.inMilliseconds,
      'x': o.x,
      'y': o.y,
      'scale': o.scale,
      'volume': o.volume,
      'hasAudio': o.hasAudio,
    };

VideoOverlay _videoOverlayFromJson(Map<String, dynamic> j) => VideoOverlay(
      id: j['id'] as String,
      path: j['path'] as String,
      name: j['name'] as String? ?? '',
      start: _dur(j, 'startMs'),
      end: _dur(j, 'endMs'),
      sourceStart: _dur(j, 'sourceStartMs'),
      x: (j['x'] as num?)?.toDouble() ?? 0.5,
      y: (j['y'] as num?)?.toDouble() ?? 0.5,
      scale: (j['scale'] as num?)?.toDouble() ?? 0.35,
      volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
      hasAudio: j['hasAudio'] as bool? ?? true,
    );

/// Serializes [project]; media paths are rewritten through [pathMap]
/// (original path -> bundle path). Pass `{}` to keep paths as-is.
Map<String, dynamic> projectToJson(
    TimelineProject project, Map<String, String> pathMap) {
  return {
    'version': projectFormatVersion,
    'tracks': [
      for (final t in project.tracks)
        {
          'id': t.id,
          'clips': [for (final c in t.clips) _clipToJson(c, pathMap)],
        }
    ],
    'overlays': [for (final o in project.overlays) _textOverlayToJson(o)],
    'audioTracks': [
      for (final t in project.audioTracks) _audioTrackToJson(t, pathMap)
    ],
    'stickers': [for (final s in project.stickers) _stickerToJson(s, pathMap)],
    'videoOverlays': [
      for (final o in project.videoOverlays) _videoOverlayToJson(o, pathMap)
    ],
  };
}

/// Parses a project written by [projectToJson]. Unknown enum names fall back
/// to defaults so old files stay loadable.
TimelineProject projectFromJson(Map<String, dynamic> j) {
  return TimelineProject(
    tracks: [
      for (final t in (j['tracks'] as List? ?? []))
        VideoTrack(
          id: (t as Map<String, dynamic>)['id'] as String,
          clips: [
            for (final c in (t['clips'] as List? ?? []))
              _clipFromJson(c as Map<String, dynamic>)
          ],
        )
    ],
    overlays: [
      for (final o in (j['overlays'] as List? ?? []))
        _textOverlayFromJson(o as Map<String, dynamic>)
    ],
    audioTracks: [
      for (final t in (j['audioTracks'] as List? ?? []))
        _audioTrackFromJson(t as Map<String, dynamic>)
    ],
    stickers: [
      for (final s in (j['stickers'] as List? ?? []))
        _stickerFromJson(s as Map<String, dynamic>)
    ],
    videoOverlays: [
      for (final o in (j['videoOverlays'] as List? ?? []))
        _videoOverlayFromJson(o as Map<String, dynamic>)
    ],
  );
}

/// Every media path referenced by [project].
Set<String> projectMediaPaths(TimelineProject project) {
  final paths = <String>{};
  for (final t in project.tracks) {
    for (final c in t.clips) {
      paths.add(c.source.path);
    }
  }
  for (final s in project.stickers) {
    paths.add(s.path);
  }
  for (final t in project.audioTracks) {
    paths.add(t.path);
  }
  for (final o in project.videoOverlays) {
    paths.add(o.path);
  }
  return paths;
}

Future<Directory> _projectsRoot() async {
  final docs = await getApplicationDocumentsDirectory();
  final root = Directory('${docs.path}/ove_projects');
  if (!await root.exists()) await root.create(recursive: true);
  return root;
}

/// Sanitizes a project name into a directory name.
String projectDirName(String name) {
  final clean =
      name.replaceAll(RegExp(r'[^\w\- ]+'), '').trim().replaceAll(' ', '_');
  return clean.isEmpty ? 'proyek' : clean;
}

/// Names of saved projects (directories containing project.json).
Future<List<String>> listProjects() async {
  final root = await _projectsRoot();
  final names = <String>[];
  await for (final e in root.list()) {
    if (e is Directory &&
        await File('${e.path}/project.json').exists()) {
      names.add(e.path.split('/').last);
    }
  }
  names.sort();
  return names;
}

/// Saves [project] as [name], copying media into the bundle.
/// Returns the list of media paths that were missing and kept as-is.
Future<List<String>> saveProject(String name, TimelineProject project) async {
  final root = await _projectsRoot();
  final dir = Directory('${root.path}/${projectDirName(name)}');
  final mediaDir = Directory('${dir.path}/media');
  if (await dir.exists()) await dir.delete(recursive: true);
  await mediaDir.create(recursive: true);

  final pathMap = <String, String>{};
  final missing = <String>[];
  var i = 0;
  for (final src in projectMediaPaths(project)) {
    final file = File(src);
    if (!await file.exists()) {
      missing.add(src);
      continue;
    }
    var base = src.split('/').last;
    if (base.isEmpty) base = 'media_$i';
    // Avoid collisions between same-named files from different folders.
    var dest = '${mediaDir.path}/$base';
    while (await File(dest).exists()) {
      i++;
      dest = '${mediaDir.path}/${i}_$base';
    }
    await file.copy(dest);
    pathMap[src] = dest;
    i++;
  }

  final json = projectToJson(project, pathMap);
  await File('${dir.path}/project.json')
      .writeAsString(jsonEncode(json));
  return missing;
}

/// Loads a saved project. Throws [ProjectLoadException] when files are gone.
Future<TimelineProject> loadProject(String name) async {
  final root = await _projectsRoot();
  final file = File('${root.path}/${projectDirName(name)}/project.json');
  if (!await file.exists()) {
    throw ProjectLoadException('Proyek "$name" tidak ditemukan.');
  }
  final project =
      projectFromJson(jsonDecode(await file.readAsString()));
  final missing = <String>[];
  for (final p in projectMediaPaths(project)) {
    if (!await File(p).exists()) missing.add(p.split('/').last);
  }
  if (missing.isNotEmpty) {
    throw ProjectLoadException(
        'File media hilang: ${missing.take(3).join(', ')}'
        '${missing.length > 3 ? ' (+${missing.length - 3} lagi)' : ''}');
  }
  return project;
}

/// Deletes a saved project and its media bundle.
Future<void> deleteProject(String name) async {
  final root = await _projectsRoot();
  final dir = Directory('${root.path}/${projectDirName(name)}');
  if (await dir.exists()) await dir.delete(recursive: true);
}

class ProjectLoadException implements Exception {
  ProjectLoadException(this.message);
  final String message;
  @override
  String toString() => message;
}
