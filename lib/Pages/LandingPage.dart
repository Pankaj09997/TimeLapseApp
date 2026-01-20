import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timelapse_app/Pages/HomePage.dart';

class LandingPage extends StatefulWidget {
  final CameraDescription cameraDescription;
  const LandingPage({super.key, required this.cameraDescription});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  bool isSelected = false;

  String? selectedValue;
  String? slowEventsValue;
  Widget CustomRadioButtons(String value, String title, String subtitle) {
    return RadioListTile(
      value: value,
      groupValue: selectedValue,
      onChanged: (newValue) {
        setState(() {
          selectedValue = newValue;
          isSelected = true;
        });
      },
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }

  Future<void> getSelectedValueAndNavigate() async {
    if (selectedValue != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("SelectedValue", selectedValue!);
      if (mounted) {
        Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                HomePage(cameraDescription: widget.cameraDescription),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("TimeLapse App")),
      body: Column(
        children: [
          CustomRadioButtons(
            "fast",
            "Fast Events",
            "Traffic, sports, people moving (captures every 0.5s)",
          ),
          CustomRadioButtons(
            "slow",
            "Slow Events",
            "Clouds, sunset, plants growing (captures every 5s)",
          ),
          Visibility(
            visible: isSelected == true,
            child: ElevatedButton(
              onPressed: () => getSelectedValueAndNavigate(),
              child: Text("Start Recording Your Timelapse"),
            ),
          ),
        ],
      ),
    );
  }
}
