import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:timelapse_app/Pages/LandingPage.dart';

//This camera Description gives us the information about the conifguration about device cameras like how many cameras are there on the users device and which camera is currently turned on by the user.
late List<CameraDescription> cameras;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Timelapse App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: LandingPage(cameraDescription: cameras.first),
    );
  }
}
