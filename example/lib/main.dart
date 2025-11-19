import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_video_trimmer/flutter_native_video_trimmer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _videoTrimmer = VideoTrimmer();
  String? pickedFile;
  String? trimmedFile;

  Future<void> pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        pickedFile = result.files.single.path;
      });
    } else {
      debugPrint("No video selected");
    }
  }

  Future<void> trimVideo() async {
    if (pickedFile == null) {
      debugPrint("No video loaded");
      return;
    }

    try {
      // Load selected video
      await _videoTrimmer.loadVideo(pickedFile!);

      // Trim first 3 seconds
      final path = await _videoTrimmer.trimVideo(
        startTimeMs: 0,
        endTimeMs: 3000,
      );

      setState(() {
        trimmedFile = path;
      });

      debugPrint("Trimmed video saved at: $path");
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  // Example of how to use the video trimmer functions
  Future<void> _exampleUsage() async {
    try {
      // 1. Load a video file
      await _videoTrimmer.loadVideo('/path/to/your/video.mp4');

      // 3. Trim the video (first 5 seconds)
      final trimmedPath = await _videoTrimmer.trimVideo(
        startTimeMs: 0,
        endTimeMs: 5000,
      );
      print('Video trimmed to: $trimmedPath');

      // 4. Clear the cache
      await _videoTrimmer.clearCache();
    } catch (e) {
      print('Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            children: [
              Padding(padding: EdgeInsetsGeometry.all(30)),
              ElevatedButton(
                onPressed: pickVideo,
                child: const Text("Pick Video"),
              ),
              const SizedBox(height: 20),

              if (pickedFile != null)
                Text(
                  "Selected file:\n$pickedFile",
                  style: const TextStyle(fontSize: 14),
                ),

              const SizedBox(height: 20),

              ElevatedButton(
                onPressed: trimVideo,
                child: const Text("Trim First 3 seconds"),
              ),

              const SizedBox(height: 20),

              if (trimmedFile != null)
                Text(
                  "Trimmed file:\n$trimmedFile",
                  style: const TextStyle(fontSize: 14),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
