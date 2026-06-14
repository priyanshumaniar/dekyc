import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../services/auth_service.dart';
import '../services/kyc_flow_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';

class KYCUploadScreen extends StatefulWidget {
  const KYCUploadScreen({super.key});

  @override
  State<KYCUploadScreen> createState() => _KYCUploadScreenState();
}

class _KYCUploadScreenState extends State<KYCUploadScreen> {
  int currentStep = 0;

  // Selected file for the current step, held as in-memory bytes so it works
  // identically on web, desktop and mobile (no dart:io File / path needed).
  Uint8List? selectedBytes;
  String? selectedName;

  // Files collected per step, keyed by doc type.
  final Map<String, Uint8List> _collected = {};
  final List<String> _docKeys = [
    'aadhaar_front',
    'aadhaar_back',
    'pan',
    'photo',
  ];

  final KycFlowService _flow = KycFlowService();
  bool _submitting = false;
  double _progress = 0;
  String _progressLabel = '';

  // The only document formats DeKYC accepts (verifier can render all of them).
  static const List<String> _allowedExtensions = ['jpg', 'jpeg', 'png', 'pdf'];

  Future<void> pickFile() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      withData: true, // ensures bytes are available on every platform
    );

    if (result == null) return; // user cancelled
    if (!mounted) return;

    final picked = result.files.single;

    // Belt-and-braces: the web picker's `accept` filter can be bypassed, so
    // re-check the extension ourselves and reject anything off the allow-list.
    final ext = picked.extension?.toLowerCase() ??
        (picked.name.contains('.')
            ? picked.name.split('.').last.toLowerCase()
            : '');
    if (!_allowedExtensions.contains(ext)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only JPG, JPEG, PNG or PDF files are allowed'),
        ),
      );
      return;
    }

    final bytes = picked.bytes;
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read the selected file')),
      );
      return;
    }
    if (bytes.length > 5 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File size exceeds 5MB')),
      );
      return;
    }
    setState(() {
      selectedBytes = bytes;
      selectedName = picked.name;
    });
  }

  void _onNextOrSubmit() {
    if (selectedBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please upload a file first')),
      );
      return;
    }
    // Save the current step's file.
    _collected[_docKeys[currentStep]] = selectedBytes!;

    if (currentStep < steps.length - 1) {
      setState(() {
        currentStep++;
        selectedBytes = null;
        selectedName = null;
      });
    } else {
      _submit();
    }
  }

  Future<void> _submit() async {
    // Submitting KYC is an Individual action: require a signed session so the
    // submission is tied to a wallet that proved key control.
    final auth = AuthService.instance;
    if (!auth.isAuthenticated) {
      await Navigator.pushNamed(context, '/login');
      if (!mounted) return;
      if (!auth.isAuthenticated) return; // user backed out of sign-in
    }
    if (auth.role == UserRole.verifier) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'You are signed in as a Verifier. Switch role to Individual '
              '(Dashboard → Switch role) to submit KYC.'),
        ),
      );
      return;
    }

    setState(() {
      _submitting = true;
      _progress = 0;
      _progressLabel = 'Starting…';
    });

    try {
      final result = await _flow.submitKyc(
        _collected,
        onProgress: (p, label) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _progressLabel = label;
          });
        },
      );
      if (!mounted) return;
      Navigator.pushReplacementNamed(
        context,
        '/kycdone',
        arguments: {
          'txHash': result.txHash,
          'cid': result.cid,
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submission failed: $e')),
      );
    }
  }

  List<Map<String, String>> steps = [
    {'title': 'Aadhaar Front', 'subtitle': 'Upload Aadhaar Card (Front Side)'},
    {'title': 'Aadhaar Back', 'subtitle': 'Upload Aadhaar Card (Back Side)'},
    {'title': 'PAN Card', 'subtitle': 'Upload PAN Card'},
    {'title': 'Profile Pic', 'subtitle': 'Upload Your Photo'},
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('Upload KYC')),
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _stepper(),
                    const SizedBox(height: 26),
                    Text(
                      'STEP ${currentStep + 1} OF ${steps.length}',
                      style: TextStyle(
                          color: p.muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      steps[currentStep]['title']!,
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      steps[currentStep]['subtitle']!,
                      style: TextStyle(color: p.muted, fontSize: 14.5),
                    ),
                    const SizedBox(height: 20),
                    _uploadZone(),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: _submitting ? null : _onNextOrSubmit,
                      child: Text(
                        currentStep == steps.length - 1
                            ? 'Encrypt & Submit'
                            : 'Next',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                        'Files are encrypted on this device before anything '
                        'leaves it.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: p.muted, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_submitting) _buildProgressOverlay(),
        ],
      ),
    );
  }

  /// Segmented progress bar (one rounded segment per step).
  Widget _stepper() {
    final p = context.pal;
    return Row(
      children: List.generate(steps.length, (i) {
        final reached = i <= currentStep;
        return Expanded(
          child: Container(
            height: 6,
            margin: EdgeInsets.only(right: i == steps.length - 1 ? 0 : 6),
            decoration: BoxDecoration(
              color: reached ? p.accent : p.surfaceAlt,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }),
    );
  }

  Widget _uploadZone() {
    final p = context.pal;
    final hasFile = selectedBytes != null;
    return InkWell(
      onTap: pickFile,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 16),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border.all(
              color: hasFile ? p.accent : p.hairline,
              width: hasFile ? 1.4 : 1),
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: hasFile
            ? Column(
                children: [
                  DeUI.iconChip(context, Icons.task_outlined,
                      color: p.success, size: 52),
                  const SizedBox(height: 12),
                  Text(
                    selectedName ?? 'file',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text('Tap to replace',
                      style: TextStyle(color: p.muted, fontSize: 12.5)),
                ],
              )
            : Column(
                children: [
                  DeUI.iconChip(context, Icons.upload_file_outlined,
                      size: 52),
                  const SizedBox(height: 12),
                  const Text('Tap to choose a file',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('JPG, JPEG, PNG or PDF · max 5 MB',
                      style: TextStyle(color: p.muted, fontSize: 12.5)),
                ],
              ),
      ),
    );
  }

  Widget _buildProgressOverlay() {
    final p = context.pal;
    return Positioned.fill(
      child: Container(
        color: p.bg.withValues(alpha: 0.92),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                  strokeWidth: 5,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _progressLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(color: p.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
