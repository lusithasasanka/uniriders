import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const UniRidersApp());
}

class UniRidersApp extends StatelessWidget {
  const UniRidersApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UniRiders',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E3A8A), // Royal Blue Primary
          primary: const Color(0xFF1E3A8A),
          secondary: const Color(0xFFF97316), // Premium Orange
          surface: const Color(0xFFF8FAFC), // Off-white/slate slate-50
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E3A8A),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const UniRidersHome(),
    );
  }
}

// Preset Avatars for Vavuniya University Students
final List<String> presetAvatars = [
  'https://api.dicebear.com/7.x/adventurer/png?seed=Felix',
  'https://api.dicebear.com/7.x/adventurer/png?seed=Aneka',
  'https://api.dicebear.com/7.x/adventurer/png?seed=Jack',
  'https://api.dicebear.com/7.x/adventurer/png?seed=Sophia',
  'https://api.dicebear.com/7.x/adventurer/png?seed=Oliver',
  'https://api.dicebear.com/7.x/adventurer/png?seed=Emma',
];

class UniRidersHome extends StatefulWidget {
  const UniRidersHome({super.key});
  @override
  State<UniRidersHome> createState() => _UniRidersHomeState();
}

class _UniRidersHomeState extends State<UniRidersHome> {
  // Session State
  bool hasProfile = false;
  String? userName;
  String? userPhone;
  bool isRider = false;
  String? bikeModel;
  String? avatarUrl;
  String? userDocId;

  // View States
  bool isRiderView = false;
  bool isOnline = false;

  // Active Request Tracking (For Passengers)
  String? activeRequestId;
  StreamSubscription<Position>? _locationSubscription;
  StreamSubscription<DocumentSnapshot>? _activeRequestSubscription;

  @override
  void initState() {
    super.initState();
    _loadUserSession();
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _activeRequestSubscription?.cancel();
    super.dispose();
  }

  // --- PERSISTENCE & SESSION LOGIC ---
  Future<void> _loadUserSession() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedName = prefs.getString('savedName');
    if (savedName != null) {
      setState(() {
        userName = savedName;
        userPhone = prefs.getString('savedPhone');
        isRider = prefs.getBool('savedIsRider') ?? false;
        bikeModel = prefs.getString('savedBike');
        avatarUrl = prefs.getString('savedAvatar') ?? presetAvatars[0];
        userDocId = prefs.getString('savedDocId');
        // If rider, start in rider view. If passenger, lock in passenger view.
        isRiderView = isRider;
        hasProfile = true;
      });

      // Synchronize/load real-time profile state from Firestore
      if (userDocId != null) {
        try {
          var userSnapshot = await FirebaseFirestore.instance.collection('users').doc(userDocId).get();
          if (userSnapshot.exists) {
            var data = userSnapshot.data();
            if (data != null) {
              setState(() {
                isOnline = data['isOnline'] ?? false;
                // Double check local SharedPreferences matches database
                isRider = data['isRider'] ?? false;
                bikeModel = data['bike'];
                avatarUrl = data['avatarUrl'] ?? presetAvatars[0];
              });
            }
          }
        } catch (e) {
          debugPrint("Error fetching database profile: $e");
        }
      }
      _checkActiveRequests();
    } else {
      Future.delayed(const Duration(milliseconds: 500), () => _showRegisterDialog());
    }
  }

  Future<void> _saveUserSession(String name, String phone, bool isRiderVal, String bike, String avatar, String docId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('savedName', name);
    await prefs.setString('savedPhone', phone);
    await prefs.setBool('savedIsRider', isRiderVal);
    await prefs.setString('savedBike', bike);
    await prefs.setString('savedAvatar', avatar);
    await prefs.setString('savedDocId', docId);
  }

  // Check if passenger has any active requests to resume live updates
  void _checkActiveRequests() {
    if (isRider) return; // Only track for passengers
    FirebaseFirestore.instance
        .collection('requests')
        .where('passengerPhone', isEqualTo: userPhone)
        .where('status', whereIn: ['pending', 'accepted'])
        .limit(1)
        .snapshots()
        .listen((snapshot) {
          if (snapshot.docs.isNotEmpty) {
            var activeDoc = snapshot.docs.first;
            setState(() {
              activeRequestId = activeDoc.id;
            });
            _startLiveLocationUpdates();
          } else {
            setState(() {
              activeRequestId = null;
            });
            _locationSubscription?.cancel();
            _locationSubscription = null;
          }
        });
  }

  // --- LOCATION & MAPS LOGIC ---
  Future<Position?> _getGPS() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location services are disabled. Please enable GPS.")),
        );
      }
      return null;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return null;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return null;
    }
    return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  // Passenger continuous live location sharing when trip accepted/pending
  void _startLiveLocationUpdates() async {
    _locationSubscription?.cancel();
    
    // Check permission first
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return;
    }

    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // Update database every 5 meters
      ),
    ).listen((Position position) {
      if (activeRequestId != null) {
        FirebaseFirestore.instance.collection('requests').doc(activeRequestId).update({
          'liveLat': position.latitude.toString(),
          'liveLon': position.longitude.toString(),
        }).catchError((e) {
          debugPrint("Error updating live location: $e");
        });
      }
    });
  }

  Future<void> _trackOnMap(String lat, String lon) async {
    if (lat.isEmpty || lon.isEmpty) return;
    final String url = "https://www.google.com/maps/search/?api=1&query=$lat,$lon";
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not open maps.")),
        );
      }
    }
  }

  // --- RIDER AVAILABILITY SWITCHER ---
  Future<void> _toggleOnlineStatus(bool value) async {
    setState(() {
      isOnline = value;
    });
    if (userDocId != null) {
      await FirebaseFirestore.instance.collection('users').doc(userDocId).update({
        'isOnline': value,
      });
    }
  }

  // --- RIDER RATING SYSTEM LOGIC ---
  Future<void> _submitRating(String riderId, double selectedStars) async {
    DocumentReference riderRef = FirebaseFirestore.instance.collection('users').doc(riderId);
    
    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        DocumentSnapshot snapshot = await transaction.get(riderRef);
        if (!snapshot.exists) return;
        
        Map<String, dynamic> data = snapshot.data() as Map<String, dynamic>;
        double currentSum = (data['ratingSum'] ?? 0.0).toDouble();
        int currentCount = data['ratingCount'] ?? 0;
        
        double nextSum = currentSum + selectedStars;
        int nextCount = currentCount + 1;
        double nextRating = nextSum / nextCount;
        
        transaction.update(riderRef, {
          'ratingSum': nextSum,
          'ratingCount': nextCount,
          'rating': double.parse(nextRating.toStringAsFixed(1)),
        });
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.green[800],
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Text("Thank you! You rated $selectedStars Stars."),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error submitting rating: $e")),
        );
      }
    }
  }

  // --- UI DIALOGS ---

  // Enhanced Registration Dialog with Role, Avatar Selection
  void _showRegisterDialog() {
    TextEditingController nameController = TextEditingController();
    TextEditingController phoneController = TextEditingController();
    TextEditingController bikeController = TextEditingController();
    bool isRiderSelected = false;
    String selectedAvatar = presetAvatars[0];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setRegState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Column(
            children: [
              Icon(Icons.directions_bike, size: 40, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              const Text(
                "UniRiders Registration",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
              ),
              const Text(
                "Vavuniya University Student Network",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          content: SizedBox(
            width: MediaQuery.of(context).size.width * 0.9,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("1. Select Student Avatar", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  // Avatar Grid Selection
                  SizedBox(
                    height: 85,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: presetAvatars.length,
                      itemBuilder: (context, idx) {
                        bool isSelected = selectedAvatar == presetAvatars[idx];
                        return GestureDetector(
                          onTap: () => setRegState(() => selectedAvatar = presetAvatars[idx]),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected ? Theme.of(context).colorScheme.secondary : Colors.transparent,
                                width: 3,
                              ),
                              boxShadow: isSelected
                                  ? [BoxShadow(color: Theme.of(context).colorScheme.secondary.withAlpha((0.3 * 255).round()), blurRadius: 6, spreadRadius: 1)]
                                  : null,
                            ),
                            child: CircleAvatar(
                              radius: 30,
                              backgroundColor: Colors.grey[200],
                              backgroundImage: NetworkImage(presetAvatars[idx]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 15),
                  const Text("2. Personal Information", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: "Full Name",
                      prefixIcon: const Icon(Icons.person),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: "Phone Number",
                      prefixIcon: const Icon(Icons.phone),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 15),
                  const Text("3. Register As", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  // Custom Segmented-style Role selection
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => setRegState(() => isRiderSelected = false),
                          icon: Icon(Icons.hail, color: !isRiderSelected ? Colors.white : Colors.blue[900]),
                          label: Text("Passenger", style: TextStyle(color: !isRiderSelected ? Colors.white : Colors.blue[900])),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: !isRiderSelected ? Colors.blue[900] : Colors.transparent,
                            side: BorderSide(color: Colors.blue[900]!),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => setRegState(() => isRiderSelected = true),
                          icon: Icon(Icons.motorcycle, color: isRiderSelected ? Colors.white : Colors.orange[700]),
                          label: Text("Rider (Bike)", style: TextStyle(color: isRiderSelected ? Colors.white : Colors.orange[700])),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: isRiderSelected ? Colors.orange[700] : Colors.transparent,
                            side: BorderSide(color: Colors.orange[700]!),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isRiderSelected) ...[
                    const SizedBox(height: 15),
                    const Text("4. Bike Details (Riders Only)", style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: bikeController,
                      decoration: InputDecoration(
                        labelText: "Motorcycle Model (e.g. Pulsar 150)",
                        prefixIcon: const Icon(Icons.pedal_bike),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () async {
                  if (nameController.text.trim().isEmpty || phoneController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Please fill in all details.")),
                    );
                    return;
                  }
                  if (isRiderSelected && bikeController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Please provide your bike model.")),
                    );
                    return;
                  }

                  // Save in Firestore
                  var userDoc = await FirebaseFirestore.instance.collection('users').add({
                    'name': nameController.text.trim(),
                    'phone': phoneController.text.trim(),
                    'isRider': isRiderSelected,
                    'bike': isRiderSelected ? bikeController.text.trim() : '',
                    'avatarUrl': selectedAvatar,
                    'isOnline': false,
                    'rating': 5.0,
                    'ratingCount': 0,
                    'ratingSum': 0.0,
                  });

                  await _saveUserSession(
                    nameController.text.trim(),
                    phoneController.text.trim(),
                    isRiderSelected,
                    isRiderSelected ? bikeController.text.trim() : '',
                    selectedAvatar,
                    userDoc.id,
                  );

                  setState(() {
                    userName = nameController.text.trim();
                    userPhone = phoneController.text.trim();
                    isRider = isRiderSelected;
                    bikeModel = isRiderSelected ? bikeController.text.trim() : '';
                    avatarUrl = selectedAvatar;
                    userDocId = userDoc.id;
                    isRiderView = isRiderSelected; // Riders default to rider dashboard
                    hasProfile = true;
                  });

                  _checkActiveRequests();
                  if (context.mounted) Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text("Start Using UniRiders", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Slider dialog to book a ride with LKR 40 / km pricing
  void _showBookingDialog() {
    TextEditingController pickupController = TextEditingController();
    TextEditingController destController = TextEditingController();
    TextEditingController distController = TextEditingController();
    String lat = "";
    String lon = "";
    double fare = 0.0;
    bool isLocating = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Icon(Icons.local_taxi, color: Colors.blue[900]),
              const SizedBox(width: 8),
              const Text("Book a UniRider", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Live Location GPS Capture Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isLocating
                        ? null
                        : () async {
                            setDState(() => isLocating = true);
                            Position? p = await _getGPS();
                            setDState(() => isLocating = false);
                            if (p != null) {
                              setDState(() {
                                lat = p.latitude.toString();
                                lon = p.longitude.toString();
                                pickupController.text = "My GPS Location shared ✅";
                              });
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue[50],
                      foregroundColor: Colors.blue[900],
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: isLocating
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.my_location),
                    label: Text(lat == "" ? "Capture My Live Location" : "Location Selected ✅"),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pickupController,
                  decoration: InputDecoration(
                    labelText: "Pickup Point / Landmark",
                    prefixIcon: const Icon(Icons.pin_drop, color: Colors.green),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: destController,
                  decoration: InputDecoration(
                    labelText: "Destination",
                    prefixIcon: const Icon(Icons.flag, color: Colors.red),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: distController,
                  decoration: InputDecoration(
                    labelText: "Estimated Distance (km)",
                    prefixIcon: const Icon(Icons.social_distance),
                    suffixText: "km",
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    double parsedDist = double.tryParse(v) ?? 0.0;
                    setDState(() {
                      // EXACTLY LKR 40 per 1 kilometer
                      fare = parsedDist * 40;
                    });
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.green[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green[200]!),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Estimated Fare:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text(
                        "LKR ${fare.toStringAsFixed(0)}",
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "Official rate: 40 Rupees per 1 Kilometer",
                  style: TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                if (pickupController.text.trim().isEmpty || destController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Pickup and Destination are required.")),
                  );
                  return;
                }
                double distance = double.tryParse(distController.text) ?? 0.0;
                if (distance <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Please enter a valid distance.")),
                  );
                  return;
                }

                // Upload request
                var docRef = await FirebaseFirestore.instance.collection('requests').add({
                  'passengerName': userName,
                  'passengerPhone': userPhone,
                  'pickup': pickupController.text.trim(),
                  'destination': destController.text.trim(),
                  'distance': distance,
                  'fare': fare,
                  'lat': lat,
                  'lon': lon,
                  'liveLat': lat,
                  'liveLon': lon,
                  'status': 'pending',
                  'timestamp': FieldValue.serverTimestamp(),
                });

                setState(() {
                  activeRequestId = docRef.id;
                });

                // Instantly trigger GPS tracking stream subscription
                _startLiveLocationUpdates();

                if (context.mounted) Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[900],
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text("Confirm & Call Rider", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // Sliding bottom sheet to show Rider Profile Card and Star Rating System
  void _showRiderProfileSheet(Map<String, dynamic> riderData, String riderDocId) {
    double givenRating = 5;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, sheetState) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(28),
              topRight: Radius.circular(28),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pull Bar
              Container(
                width: 50,
                height: 5,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)),
              ),
              const SizedBox(height: 20),
              // Rider Avatar
              CircleAvatar(
                radius: 50,
                backgroundColor: Colors.orange[50],
                backgroundImage: NetworkImage(riderData['avatarUrl'] ?? presetAvatars[0]),
              ),
              const SizedBox(height: 12),
              // Rider Name
              Text(
                riderData['name'],
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24, letterSpacing: 0.5),
              ),
              const SizedBox(height: 4),
              // Bike Details
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.motorcycle, size: 18, color: Colors.orange),
                  const SizedBox(width: 6),
                  Text(
                    riderData['bike'] ?? 'Motorcycle Rider',
                    style: TextStyle(fontSize: 16, color: Colors.grey[700], fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Average Rating Widget
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 22),
                  const SizedBox(width: 4),
                  Text(
                    "${riderData['rating'] ?? '5.0'}",
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    " (${riderData['ratingCount'] ?? 0} reviews)",
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                ],
              ),
              const Divider(height: 30, thickness: 1),
              // Call Rider Button
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.blue[50], child: const Icon(Icons.phone, color: Colors.blue)),
                title: const Text("Call Rider"),
                subtitle: Text(riderData['phone']),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final Uri telUri = Uri.parse("tel:${riderData['phone']}");
                  if (await canLaunchUrl(telUri)) {
                    await launchUrl(telUri);
                  }
                },
              ),
              const SizedBox(height: 15),
              // Rate Rider Panel
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  children: [
                    const Text(
                      "Rate this Rider",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E3A8A)),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (starIndex) {
                        int starVal = starIndex + 1;
                        return IconButton(
                          icon: Icon(
                            givenRating >= starVal ? Icons.star : Icons.star_border,
                            color: Colors.amber,
                            size: 32,
                          ),
                          onPressed: () {
                            sheetState(() {
                              givenRating = starVal.toDouble();
                            });
                          },
                        );
                      }),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(context); // close sheet
                          await _submitRating(riderDocId, givenRating);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber[700],
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text("Submit Rating", style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- CORE BUILD & ROUTING ENGINE ---

  @override
  Widget build(BuildContext context) {
    if (!hasProfile) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 15),
              Text(
                "Loading UniRiders Session...",
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.directions_bike, size: 28),
            const SizedBox(width: 8),
            Text(
              isRiderView ? "RIDER PORTAL" : "PASSENGER HUB",
              style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
          ],
        ),
        backgroundColor: isRiderView ? Colors.orange[800] : Colors.blue[900],
        actions: [
          // STAGE 2 restriction: "passenger cant go to riders mode"
          // ONLY registered Riders can toggle views! Passengers never see the switch.
          if (isRider)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: ActionChip(
                backgroundColor: isRiderView ? Colors.blue[900] : Colors.orange[800],
                avatar: const Icon(Icons.sync, color: Colors.white, size: 16),
                label: Text(
                  isRiderView ? "Go Passenger" : "Go Rider",
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                onPressed: () {
                  setState(() {
                    isRiderView = !isRiderView;
                  });
                },
              ),
            ),
        ],
      ),
      body: isRiderView ? _buildRiderView() : _buildPassengerView(),
      floatingActionButton: isRiderView
          ? null
          : (activeRequestId != null
              ? null
              : FloatingActionButton.extended(
                  onPressed: _showBookingDialog,
                  backgroundColor: Colors.blue[900],
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.add_road),
                  label: const Text("Book a Ride"),
                )),
    );
  }

  // --- PASSENGER VIEW HUB ---
  Widget _buildPassengerView() {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() {}); // Pull to refresh screen details
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Elegant Welcome Header Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            decoration: BoxDecoration(
              color: Colors.blue[900],
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: Colors.white,
                  backgroundImage: NetworkImage(avatarUrl ?? presetAvatars[0]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Welcome, ${userName ?? 'Student'}",
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.blue[800],
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          "🎓 Vavuniya University Student",
                          style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Active Trip Tracker Card (If passenger has a request in progress)
          if (activeRequestId != null) _buildActiveRequestTracker(),

          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              "Available Riders in the Moment",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blueGrey),
            ),
          ),

          // List of ONLINE/AVAILABLE RIDERS with profiles & ratings
          Expanded(
            child: StreamBuilder(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .where('isRider', isEqualTo: true)
                  .where('isOnline', isEqualTo: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.no_accounts, size: 65, color: Colors.grey[400]),
                          const SizedBox(height: 12),
                          const Text(
                            "No Available Riders Online Now",
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.grey),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "Riders show up here when they go Online.",
                            style: TextStyle(color: Colors.grey[500], fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                var docs = snapshot.data!.docs;
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    var rider = docs[i].data();
                    var docId = docs[i].id;
                    double ratingVal = (rider['rating'] ?? 5.0).toDouble();

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: InkWell(
                        onTap: () => _showRiderProfileSheet(rider, docId),
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Row(
                            children: [
                              // Rider Avatar with Online status indicator
                              Stack(
                                children: [
                                  CircleAvatar(
                                    radius: 30,
                                    backgroundColor: Colors.orange[50],
                                    backgroundImage: NetworkImage(rider['avatarUrl'] ?? presetAvatars[0]),
                                  ),
                                  const Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: CircleAvatar(
                                      radius: 8,
                                      backgroundColor: Colors.white,
                                      child: CircleAvatar(
                                        radius: 6,
                                        backgroundColor: Colors.green, // Live Online indicator
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 14),
                              // Rider Details
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      rider['name'],
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                    const SizedBox(height: 3),
                                    Row(
                                      children: [
                                        const Icon(Icons.motorcycle, size: 14, color: Colors.grey),
                                        const SizedBox(width: 4),
                                        Text(
                                          rider['bike'] ?? 'Motorcycle',
                                          style: TextStyle(color: Colors.grey[600], fontSize: 13),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    // Ratings display
                                    Row(
                                      children: [
                                        const Icon(Icons.star, color: Colors.amber, size: 16),
                                        const SizedBox(width: 4),
                                        Text(
                                          ratingVal.toString(),
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          "(${rider['ratingCount'] ?? 0} ratings)",
                                          style: TextStyle(color: Colors.grey[500], fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              // Call-to-Action Profile button
                              Icon(Icons.arrow_forward_ios, size: 16, color: Colors.blue[900]),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Beautiful UI Card tracking the active request for Passengers
  Widget _buildActiveRequestTracker() {
    return StreamBuilder(
      stream: FirebaseFirestore.instance.collection('requests').doc(activeRequestId).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }
        var req = snapshot.data!.data() as Map<String, dynamic>;
        String status = req['status'] ?? 'pending';

        Color statusColor = Colors.orange;
        String statusText = "Waiting for Rider...";
        IconData statusIcon = Icons.hourglass_empty;

        if (status == 'accepted') {
          statusColor = Colors.green;
          statusText = "Rider accepted! Sharing Location live ✅";
          statusIcon = Icons.motorcycle;
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blue[900]!, Colors.blue[800]!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.blue[900]!.withAlpha((0.3 * 255).round()),
                blurRadius: 10,
                offset: const Offset(0, 4),
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Active Booking Status",
                    style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  ActionChip(
                    backgroundColor: statusColor,
                    avatar: Icon(statusIcon, color: Colors.white, size: 14),
                    label: Text(
                      statusText,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    onPressed: () {},
                  )
                ],
              ),
              const SizedBox(height: 10),
              Text(
                "Route: ${req['pickup']} ➡️ ${req['destination']}",
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Fare: LKR ${req['fare']}",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: Colors.red[200]),
                    icon: const Icon(Icons.cancel, size: 16),
                    label: const Text("Cancel Ride", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    onPressed: () {
                      FirebaseFirestore.instance.collection('requests').doc(activeRequestId).update({
                        'status': 'cancelled',
                      });
                      setState(() {
                        activeRequestId = null;
                      });
                      _locationSubscription?.cancel();
                    },
                  )
                ],
              )
            ],
          ),
        );
      },
    );
  }

  // --- RIDER MODE PORTAL ---
  Widget _buildRiderView() {
    return Column(
      children: [
        // Rider Availability Controller Banner (Glassmorphism inspired)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.orange[800],
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(30),
              bottomRight: Radius.circular(30),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      // Pulsating indicator
                      CircleAvatar(
                        radius: 7,
                        backgroundColor: isOnline ? Colors.greenAccent : Colors.grey[400],
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isOnline ? "YOU ARE ONLINE (Available)" : "YOU ARE OFFLINE (Busy)",
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ],
                  ),
                  Switch(
                    value: isOnline,
                    activeThumbColor: Colors.greenAccent,
                    activeTrackColor: Colors.green[900],
                    inactiveThumbColor: Colors.grey[300],
                    inactiveTrackColor: Colors.orange[900],
                    onChanged: (val) => _toggleOnlineStatus(val),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                "Toggle Online to let passengers find you in Vavuniya University",
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),

        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Row(
            children: [
              Icon(Icons.playlist_add_check, color: Colors.orange),
              SizedBox(width: 8),
              Text(
                "Active & Pending Ride Requests",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blueGrey),
              ),
            ],
          ),
        ),

        // Stream of incoming/pending requests
        Expanded(
          child: StreamBuilder(
            stream: FirebaseFirestore.instance
                .collection('requests')
                .where('status', whereIn: ['pending', 'accepted'])
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.motorcycle_outlined, size: 60, color: Colors.grey[400]),
                      const SizedBox(height: 12),
                      const Text(
                        "No student ride requests at the moment.",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              var reqs = snapshot.data!.docs;
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                itemCount: reqs.length,
                itemBuilder: (context, i) {
                  var req = reqs[i].data();
                  var reqId = reqs[i].id;
                  String status = req['status'] ?? 'pending';

                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "Passenger: ${req['passengerName']}",
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: status == 'accepted' ? Colors.green[50] : Colors.orange[50],
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: status == 'accepted' ? Colors.green[200]! : Colors.orange[200]!),
                                ),
                                child: Text(
                                  status.toUpperCase(),
                                  style: TextStyle(
                                    color: status == 'accepted' ? Colors.green[800] : Colors.orange[800],
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 18),
                          Row(
                            children: [
                              const Icon(Icons.pin_drop, color: Colors.green, size: 18),
                              const SizedBox(width: 6),
                              Expanded(child: Text("Pickup: ${req['pickup']}")),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.flag, color: Colors.red, size: 18),
                              const SizedBox(width: 6),
                              Expanded(child: Text("Dest: ${req['destination']}")),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "Fare: LKR ${req['fare']} (${req['distance']} km)",
                                style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              Text(
                                "Phone: ${req['passengerPhone'] ?? 'N/A'}",
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                          const Divider(height: 18),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // Live GPS Tracking Button
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue[900],
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: const Icon(Icons.map, size: 16),
                                label: Text(status == 'accepted' ? "TRACK LIVE GPS" : "VIEW PICKUP"),
                                onPressed: () {
                                  // For accepted trips, use live passenger GPS updates if available, fallback to pickup GPS
                                  String trackLat = (status == 'accepted' && req['liveLat'] != null && req['liveLat'].toString().isNotEmpty)
                                      ? req['liveLat'].toString()
                                      : req['lat'].toString();
                                  String trackLon = (status == 'accepted' && req['liveLon'] != null && req['liveLon'].toString().isNotEmpty)
                                      ? req['liveLon'].toString()
                                      : req['lon'].toString();
                                  _trackOnMap(trackLat, trackLon);
                                },
                              ),
                              const SizedBox(width: 8),
                              if (status == 'pending')
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green[700],
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  onPressed: () {
                                    FirebaseFirestore.instance.collection('requests').doc(reqId).update({
                                      'status': 'accepted',
                                      'riderId': userDocId,
                                      'riderName': userName,
                                    });
                                  },
                                  child: const Text("ACCEPT"),
                                ),
                              if (status == 'accepted') ...[
                                TextButton(
                                  style: TextButton.styleFrom(foregroundColor: Colors.red[800]),
                                  onPressed: () {
                                    FirebaseFirestore.instance.collection('requests').doc(reqId).update({
                                      'status': 'pending',
                                      'riderId': null,
                                      'riderName': null,
                                    });
                                  },
                                  child: const Text("RELEASE"),
                                ),
                                const SizedBox(width: 4),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green[800],
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  onPressed: () {
                                    FirebaseFirestore.instance.collection('requests').doc(reqId).update({
                                      'status': 'completed',
                                    });
                                  },
                                  child: const Text("COMPLETE"),
                                ),
                              ],
                            ],
                          )
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}