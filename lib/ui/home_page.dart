import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Clipboard
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/project_info.dart';
import '../services/database_service.dart';
import '../services/google_sheets_service.dart';
import '../services/image_service.dart';
import '../services/ocr_service.dart';
import '../utils/text_utils.dart';

class OCRHomePage extends StatefulWidget {
  const OCRHomePage({super.key});

  @override
  State<OCRHomePage> createState() => _OCRHomePageState();
}
class _OCRHomePageState extends State<OCRHomePage>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {

  @override
  bool get wantKeepAlive => true;

  // Navigation State
  late TabController _tabController;
  int _currentIndex = 0;
  
  // Data State
  final ImagePicker _picker = ImagePicker();
  final List<XFile> _pages = [];
  String _fullText = '';
  bool _isProcessing = false;
  List<ProjectInfo> _projects = [];
  int? _editingProjectId;

  // Controllers
  final _titleController = TextEditingController();
  final _abstractController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _categoryController = TextEditingController();
  final _technologiesController = TextEditingController();
  
  // Student List Logic
  final _studentEntryController = TextEditingController(); 
  List<String> _studentNamesList = []; 
  
  final _supervisorController = TextEditingController();
  final _yearController = TextEditingController(text: DateTime.now().year.toString());
  final _keywordsController = TextEditingController();

  @override
  void initState() {
    super.initState();
  _tabController = TabController(length: 3, vsync: this);
_tabController.addListener(() {
  if (_tabController.indexIsChanging) {
    setState(() {
      _currentIndex = _tabController.index;
    });
  }
});


    _loadProjects();
    _restoreDraft();
    
    // Auto-Save Listeners
    _titleController.addListener(_saveDraft);
    _abstractController.addListener(_saveDraft);
    _descriptionController.addListener(_saveDraft);
    _categoryController.addListener(_saveDraft);
    _technologiesController.addListener(_saveDraft);
    _supervisorController.addListener(_saveDraft);
    _keywordsController.addListener(_saveDraft);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _abstractController.dispose();
    _descriptionController.dispose();
    _categoryController.dispose();
    _technologiesController.dispose();
    _studentEntryController.dispose();
    _supervisorController.dispose();
    _yearController.dispose();
    _keywordsController.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    final list = await DatabaseService.getAllProjects();
    if (mounted) setState(() => _projects = list);
  }

  // --- 0. Auto-Save Logic ---
  Future<void> _saveDraft() async {
    if (_editingProjectId != null) return; 
    
    final prefs = await SharedPreferences.getInstance();
    final draftData = {
      'title': _titleController.text,
      'abstract': _abstractController.text,
      'desc': _descriptionController.text,
      'cat': _categoryController.text,
      'tech': _technologiesController.text,
      'sup': _supervisorController.text,
      'key': _keywordsController.text,
      'students': _studentNamesList,
      'raw': _fullText, 
    };
    await prefs.setString('draft_form', jsonEncode(draftData));
  }

  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final draftString = prefs.getString('draft_form');
    if (draftString != null && draftString.isNotEmpty) {
      try {
        final data = jsonDecode(draftString);
        setState(() {
          _titleController.text = data['title'] ?? '';
          _abstractController.text = data['abstract'] ?? '';
          _descriptionController.text = data['desc'] ?? '';
          _categoryController.text = data['cat'] ?? '';
          _technologiesController.text = data['tech'] ?? '';
          _supervisorController.text = data['sup'] ?? '';
          _keywordsController.text = data['key'] ?? '';
          _fullText = data['raw'] ?? ''; 
          if (data['students'] != null) {
            _studentNamesList = List<String>.from(data['students']);
          }
        });
        if (_titleController.text.isNotEmpty) {
          _showSnack('Draft restored', isSuccess: true);
        }
      } catch (e) {
        debugPrint("Error restoring draft: $e");
      }
    }
  }

  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('draft_form');
  }

  // --- Confirmation Dialogs ---
  Future<void> _confirmClearForm() async {
    final confirmed = await _showConfirmDialog('Clear Form?', 'This will wipe all text and images.');
    if (confirmed) {
      _clearForm();
      _showSnack('Form cleared', isSuccess: true);
    }
  }

  Future<void> _confirmDeleteAllProjects() async {
    final confirmed = await _showConfirmDialog('Delete All Projects?', 'This will permanently delete all saved projects from the device.');
    if (confirmed) {
      // Loop delete to avoid static method issues
      for (var p in _projects) {
        if (p.id != null) {
          await DatabaseService.deleteProject(p.id!);
        }
      }
      _loadProjects();
      _showSnack('All projects deleted', isSuccess: true);
    }
  }

  Future<bool> _showConfirmDialog(String title, String content) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    return result ?? false;
  }

  // --- Image Source Selection Dialog ---
  Future<ImageSource?> _showImageSourceDialog() async {
    return await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose Image Source'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.indigo, size: 32),
              title: const Text('Camera', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.indigo, size: 32),
              title: const Text('Gallery', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Choose from photos'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  // --- 1. OCR Logic ---
  Future<void> _addPage(ImageSource source) async {
    final img = await _picker.pickImage(source: source);
    if (img != null) setState(() => _pages.add(img));
  }

  // UPDATED: Scan and Append with Camera/Gallery choice
  Future<void> _scanAndAppend(TextEditingController controller) async {
    // Show dialog to choose Camera or Gallery
    final ImageSource? source = await _showImageSourceDialog();
    if (source == null) return; // User cancelled

    try {
      final img = await _picker.pickImage(source: source);
      if (img == null) return;

      _showSnack('Processing image...', isSuccess: true);
      
      final processedFile = await ImageService.preprocessImage(img.path);
      final inputImage = InputImage.fromFilePath(processedFile.path);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      
      final result = await recognizer.processImage(inputImage);
      final cleanText = TextUtils.cleanOcrText(result.text);
      
      setState(() {
        // Append with a newline if text already exists
        if (controller.text.isNotEmpty) {
           controller.text = "${controller.text}\n\n$cleanText";
        } else {
           controller.text = cleanText;
        }
        
        // Also add to global pages/text for record keeping
        _pages.add(img);
        _fullText = "${_fullText}\n\n--- Appended Page ---\n$cleanText";
      });

      recognizer.close();
      _showSnack('Text appended successfully!', isSuccess: true);
    } catch (e) {
      _showSnack('Error appending text: $e', isError: true);
    }
  }

Future<void> _runOcr() async {
  if (_pages.isEmpty) {
    _showSnack('Add at least one page first', isError: true);
    return;
  }

  setState(() => _isProcessing = true);

  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  StringBuffer buffer = StringBuffer();

  try {
    for (var page in _pages) {
      final processedFile =
          await ImageService.preprocessImage(page.path);

      final inputImage =
          InputImage.fromFilePath(processedFile.path);

      final result =
          await recognizer.processImage(inputImage);

      buffer.writeln(
          TextUtils.cleanOcrText(result.text));
    }

    _fullText = buffer.toString();

    await _fillForms(_fullText);

    _showSnack(
      'OCR + AI Processing Complete!',
      isSuccess: true,
    );

  } catch (e) {
    _showSnack('OCR Error: $e', isError: true);
  } finally {
    recognizer.close();
    if (mounted) {
      setState(() => _isProcessing = false);
    }
  }
}


 Future<void> _fillForms(String text) async {
  final fields = await OcrService.processOCR(text);

  if (!mounted) return;

  setState(() {
    String getField(String key) {
    final v = fields[key];
    if (v == null) return '';
    if (v is String) return v;
    if (v is Map && v.containsKey('value')) return v['value'] ?? '';
    return '';
    }

    _titleController.text = getField('title');
    _abstractController.text = getField('abstract');
    _descriptionController.text = getField('description');
    _supervisorController.text = getField('supervisor');
    _yearController.text = getField('year');
    _technologiesController.text = getField('technologies');
    _keywordsController.text = getField('keywords');
    _categoryController.text = getField('category');

    final studentsRaw = getField('students');

    if (studentsRaw.isNotEmpty) {
      _studentNamesList = studentsRaw
          .split(RegExp(r'[,|;]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e.length > 2)
          .toList();
      print('[HOME] Students extracted: $_studentNamesList');
    } else {
      print('[HOME] No students found in OCR result');
      _studentNamesList.clear();
    }

    _saveDraft();
  });
}


  // --- 2. Saving & Editing Logic ---
  void _startEditing(ProjectInfo project) {
    setState(() {
      _editingProjectId = project.id;
      _titleController.text = project.title;
      _abstractController.text = project.abstractText;
      _descriptionController.text = project.description;
      _categoryController.text = project.category;
      _technologiesController.text = project.technologies.join(', ');
      _keywordsController.text = project.extractedKeywords.join(', ');
      _studentNamesList = List.from(project.studentNames);
      _supervisorController.text = project.supervisorName;
      _yearController.text = project.year;
      _fullText = project.rawOcrText;
      _pages.clear();
      _tabController.animateTo(0); // Go to Form
    });
  }

  void _cancelEditing() {
    _clearForm();
    FocusScope.of(context).unfocus();
  }

  void _addStudent() {
    final name = _studentEntryController.text.trim();
    if (name.isNotEmpty) {
      setState(() {
        if (!_studentNamesList.contains(name)) {
          _studentNamesList.add(name);
          _saveDraft();
        }
        _studentEntryController.clear();
      });
    }
  }

  // UPDATED: Scan student names with Camera/Gallery choice
  Future<void> _scanStudentNames() async {
    // Show dialog to choose Camera or Gallery
    final ImageSource? source = await _showImageSourceDialog();
    if (source == null) return; // User cancelled

    try {
      final img = await _picker.pickImage(source: source);
      if (img == null) return;

      _showSnack('Extracting student names...', isSuccess: true);
      
      final processedFile = await ImageService.preprocessImage(img.path);
      final inputImage = InputImage.fromFilePath(processedFile.path);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      
      final result = await recognizer.processImage(inputImage);
      final cleanText = TextUtils.cleanOcrText(result.text);
      
      // Parse student names from the extracted text
      List<String> extractedNames = cleanText.split(RegExp(r'[,|\n]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e.length > 2) // Filter out very short strings
          .toList();

      setState(() {
        for (var name in extractedNames) {
          if (!_studentNamesList.contains(name)) {
            _studentNamesList.add(name);
          }
        }
        // Also add to global pages/text for record keeping
        _pages.add(img);
        _fullText = "$_fullText\n\n--- Student Names Scan ---\n$cleanText";
        _saveDraft();
      });

      recognizer.close();
      
      if (extractedNames.isEmpty) {
        _showSnack('No names detected. Please add manually.', isError: true);
      } else {
        _showSnack('Found ${extractedNames.length} name(s)!', isSuccess: true);
      }
    } catch (e) {
      _showSnack('Error extracting names: $e', isError: true);
    }
  }

  Future<void> _saveLocal() async {
    if (_titleController.text.isEmpty) {
      _showSnack('Project Title is required', isError: true);
      return;
    }

    final project = ProjectInfo(
      id: _editingProjectId,
      title: _titleController.text,
      abstractText: _abstractController.text,
      description: _descriptionController.text,
      category: _categoryController.text,
      technologies: _technologiesController.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      extractedKeywords: _keywordsController.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      studentNames: _studentNamesList,
      supervisorName: _supervisorController.text,
      year: _yearController.text,
      rawOcrText: _fullText,
      isSynced: false,
    );

    if (_editingProjectId != null) {
      await DatabaseService.updateProject(project);
      _showSnack('Project Updated!', isSuccess: true);
    } else {
      await DatabaseService.insertProject(project);
      _showSnack('Project Saved!', isSuccess: true);
    }
    
    _clearForm();
    _loadProjects();
    _tabController.animateTo(2); // Go to Projects Tab
  }

  void _clearForm() {
    _clearDraft();
    setState(() {
      _editingProjectId = null;
      _pages.clear();
      _fullText = '';
      _titleController.clear();
      _abstractController.clear();
      _descriptionController.clear();
      _categoryController.clear();
      _technologiesController.clear();
      _studentEntryController.clear();
      _studentNamesList.clear();
      _supervisorController.clear();
      _keywordsController.clear();
      _yearController.text = DateTime.now().year.toString();
    });
  }

  // --- 3. Sync Logic ---
  Future<void> _syncAll() async {
    final unsynced = _projects.where((p) => !p.isSynced).toList();
    if (unsynced.isEmpty) return;

    _showSnack('Syncing ${unsynced.length} projects...', isSuccess: true);
    int count = 0;
    for (var p in unsynced) {
      final success = await GoogleSheetsService.uploadProject(p);
      if (success) {
        await DatabaseService.updateProject(p.copyWith(isSynced: true));
        count++;
      }
    }
    _loadProjects();
    _showSnack('Batch Sync: $count/${unsynced.length} uploaded.', isSuccess: true);
  }
  
  void _uploadSingle(ProjectInfo p) async {
      _showSnack('Syncing...', isSuccess: true);
      final success = await GoogleSheetsService.uploadProject(p);
      if (success) {
        await DatabaseService.updateProject(p.copyWith(isSynced: true));
        _loadProjects();
        _showSnack('Synced successfully!', isSuccess: true);
      } else {
        _showSnack('Failed to sync.', isError: true);
      }
  }

  void _showSnack(String msg, {bool isError = false, bool isSuccess = false}) {
    Color color = Colors.grey[800]!;
    if (isError) color = Colors.red[700]!;
    if (isSuccess) color = Colors.green[700]!;
    
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 2),
    ));
  }

  // --- UI BUILD ---
  @override
  Widget build(BuildContext context) {
      super.build(context);

    
    final isEditing = _editingProjectId != null;
    final unsyncedCount = _projects.where((p) => !p.isSynced).length;
    
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        elevation: 0,
        backgroundColor: isEditing ? Colors.orange[800] : Colors.indigo[800],
        title: Text(
          isEditing ? 'Edit Project' : 'Graduation OCR',
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(icon: Icon(Icons.document_scanner), text: 'Form'),
            Tab(icon: Icon(Icons.text_snippet), text: 'Raw OCR'), 
            Tab(icon: Icon(Icons.folder), text: 'Projects'),
          ],
        ),
        actions: [
          if (isEditing)
            IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: _cancelEditing, tooltip: "Cancel Edit"),
          if (_currentIndex == 0 && !isEditing) 
             IconButton(icon: const Icon(Icons.delete_sweep_outlined, color: Colors.white), onPressed: _confirmClearForm, tooltip: "Clear Form"),
          if (_currentIndex == 2) 
             IconButton(icon: const Icon(Icons.delete_forever, color: Colors.white), onPressed: _confirmDeleteAllProjects, tooltip: "Delete ALL Projects"),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFormPage(isEditing),
          _buildRawOcrPage(), 
          _buildListPage(),
        ],
      ),
      floatingActionButton: _currentIndex == 2
          ? FloatingActionButton.extended(
              onPressed: unsyncedCount > 0 ? _syncAll : null,
              backgroundColor: unsyncedCount > 0 ? Colors.indigo[800] : Colors.green[600],
              icon: Icon(unsyncedCount > 0 ? Icons.cloud_upload : Icons.check_circle, color: Colors.white),
              label: Text(unsyncedCount > 0 ? 'Sync All ($unsyncedCount)' : 'All Synced', style: const TextStyle(color: Colors.white)),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  // --- TAB 1: FORM ---
  Widget _buildFormPage(bool isEditing) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isEditing)
            Container(
              margin: const EdgeInsets.only(bottom: 20),
              padding: const EdgeInsets.all(12),
              color: Colors.orange[50],
              child: Row(children: [
                 const Icon(Icons.edit_note, color: Colors.orange),
                 const SizedBox(width: 10),
                 Expanded(child: Text("Editing '${_titleController.text}'.", style: TextStyle(color: Colors.orange[900])))
              ]),
            ),

          if (!isEditing) ...[
            _buildSectionHeader('1. Scan Documents'),
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(children: [
                        Expanded(child: _buildBigButton(Icons.camera_alt, 'Camera', () => _addPage(ImageSource.camera))),
                        const SizedBox(width: 12),
                        Expanded(child: _buildBigButton(Icons.photo_library, 'Gallery', () => _addPage(ImageSource.gallery))),
                    ]),
                    const SizedBox(height: 12),
                    if (_pages.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Icon(Icons.check_circle, color: Colors.green, size: 20),
                            const SizedBox(width: 8),
                            Text('${_pages.length} pages ready', style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.bold)),
                        ]),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(width: double.infinity, child: ElevatedButton.icon(
                        onPressed: _isProcessing ? null : _runOcr,
                        icon: _isProcessing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.auto_awesome),
                        label: Text(_isProcessing ? 'Processing...' : 'Extract Text (OCR)'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                    )),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          _buildSectionHeader('2. Details'),
          _buildInput(_titleController, 'Project Title', Icons.title),
          _buildStudentListInput(),
          const SizedBox(height: 16),
          _buildRowInputs(_yearController, 'Year', Icons.calendar_today, _categoryController, 'Category', Icons.category),
          _buildInput(_supervisorController, 'Supervisor', Icons.person),
          _buildInput(_technologiesController, 'Technologies', Icons.computer, enableScan: true),
          _buildInput(_keywordsController, 'Keywords', Icons.tag, enableScan: true),
          
          // IMPORTANT: Enable Scan for Abstract and Description
          _buildInput(_abstractController, 'Abstract', Icons.description, maxLines: 4, enableScan: true),
          _buildInput(_descriptionController, 'Description', Icons.info_outline, maxLines: 4, enableScan: true),

          const SizedBox(height: 32),
          SizedBox(height: 54, child: ElevatedButton.icon(
              onPressed: _saveLocal,
              style: ElevatedButton.styleFrom(backgroundColor: isEditing ? Colors.orange[800] : Colors.green[700]),
              icon: Icon(isEditing ? Icons.update : Icons.save, color: Colors.white),
              label: Text(isEditing ? 'Update Project' : 'Save Project', style: const TextStyle(fontSize: 18, color: Colors.white)),
          )),
        ],
      ),
    );
  }
  
  // --- TAB 2: RAW OCR & IMAGE ---
  Widget _buildRawOcrPage() {
    if (_fullText.isEmpty && _pages.isEmpty) {
      return Center(child: Text("No OCR data yet.\nScan a document first.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[500])));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pages.isNotEmpty)
            SizedBox(
              height: 200,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _pages.length,
                itemBuilder: (ctx, i) => Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Image.file(File(_pages[i].path)),
                ),
              ),
            ),
          const SizedBox(height: 16),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Extracted Text", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: "Copy All",
                onPressed: () {
                   Clipboard.setData(ClipboardData(text: _fullText));
                   _showSnack("Copied to clipboard", isSuccess: true);
                },
              )
            ],
          ),
          
          // Helper Buttons (Now Appending)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ActionChip(
                  label: const Text("Append to Abstract"), 
                  onPressed: () { 
                    _abstractController.text = "${_abstractController.text}\n\n$_fullText";
                    _tabController.animateTo(0); 
                    _showSnack("Appended to Abstract", isSuccess: true);
                  }
                ),
                const SizedBox(width: 8),
                ActionChip(
                  label: const Text("Append to Description"), 
                  onPressed: () { 
                    _descriptionController.text = "${_descriptionController.text}\n\n$_fullText"; 
                    _tabController.animateTo(0);
                    _showSnack("Appended to Description", isSuccess: true);
                  }
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey[300]!)),
            child: SelectableText(_fullText, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }

  // --- TAB 3: PROJECTS LIST ---
  Widget _buildListPage() {
    if (_projects.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.folder_copy_outlined, size: 80, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('No projects yet', style: TextStyle(color: Colors.grey[500], fontSize: 16)),
      ]));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (ctx, i) {
        final p = _projects[i];
        return Dismissible(
          key: Key(p.id.toString()),
          background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
          direction: DismissDirection.endToStart,
          confirmDismiss: (dir) => _showConfirmDialog("Delete Project?", "This cannot be undone."),
          onDismissed: (dir) async {
             await DatabaseService.deleteProject(p.id!);
             _loadProjects();
          },
          child: Card(
            elevation: 3,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _startEditing(p),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(p.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                        if (p.isSynced) const Icon(Icons.check_circle, color: Colors.green) else const Icon(Icons.cloud_off, color: Colors.orange),
                        PopupMenuButton(
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.more_vert),
                          onSelected: (val) {
                            if (val == 'edit') _startEditing(p);
                            if (val == 'sync') _uploadSingle(p);
                            if (val == 'delete') {
                              DatabaseService.deleteProject(p.id!);
                              _loadProjects();
                            }
                          },
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(value: 'edit', child: Text('Edit')),
                            if (!p.isSynced) const PopupMenuItem(value: 'sync', child: Text('Sync')),
                            const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.red))),
                          ],
                        )
                      ],
                    ),
                    Text(p.supervisorName.isNotEmpty ? p.supervisorName : "No Supervisor", style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 4, children: p.studentNames.take(3).map((s) => Chip(label: Text(s, style: const TextStyle(fontSize: 10)), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap)).toList()),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Widgets ---
  
  Widget _buildStudentListInput() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
             Expanded(child: TextField(
               controller: _studentEntryController, 
               decoration: InputDecoration(
                 labelText: 'Add Student Name', 
                 prefixIcon: const Icon(Icons.person_add), 
                 filled: true, 
                 fillColor: Colors.white, 
                 border: OutlineInputBorder(
                   borderRadius: BorderRadius.circular(12), 
                   borderSide: BorderSide.none
                 )
               ), 
               onSubmitted: (_) => _addStudent()
             )),
             const SizedBox(width: 8),
             // Manual Add Button
             FloatingActionButton.small(
               onPressed: _addStudent, 
               backgroundColor: Colors.indigo, 
               child: const Icon(Icons.add, color: Colors.white), 
               heroTag: "add_student"
             ),
             const SizedBox(width: 8),
             // Camera/Gallery Scan Button
             FloatingActionButton.small(
               onPressed: _scanStudentNames, 
               backgroundColor: Colors.green[700], 
               child: const Icon(Icons.camera_alt, color: Colors.white), 
               heroTag: "scan_students",
               tooltip: "Scan Names"
             ),
        ]),
        if (_studentNamesList.isNotEmpty) 
          Padding(
            padding: const EdgeInsets.only(top: 8), 
            child: Wrap(
              spacing: 8, 
              children: _studentNamesList.map((n) => Chip(
                label: Text(n), 
                onDeleted: () => setState(() { 
                  _studentNamesList.remove(n); 
                  _saveDraft(); 
                })
              )).toList()
            )
          ),
    ]);
  }

  Widget _buildSectionHeader(String title) => Padding(padding: const EdgeInsets.only(bottom: 12, left: 4), child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.grey[600])));
  
  Widget _buildBigButton(IconData icon, String label, VoidCallback onTap) => InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: Container(padding: const EdgeInsets.symmetric(vertical: 16), decoration: BoxDecoration(border: Border.all(color: Colors.grey[300]!), borderRadius: BorderRadius.circular(12)), child: Column(children: [Icon(icon, size: 32, color: Colors.indigo[400]), const SizedBox(height: 8), Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[800]))])));
  
  // UPDATED: Scan icon now shows dialog for Camera/Gallery choice
  Widget _buildInput(TextEditingController c, String label, IconData icon, {int maxLines = 1, bool enableScan = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 16), 
    child: TextField(
      controller: c, 
      maxLines: maxLines, 
      decoration: InputDecoration(
        labelText: label, 
        prefixIcon: Icon(icon, size: 22, color: Colors.grey[500]),
        // The Magic Button - now with Camera/Gallery dialog:
        suffixIcon: enableScan ? IconButton(
          icon: const Icon(Icons.add_a_photo, color: Colors.indigo), 
          tooltip: "Scan & Append Text",
          onPressed: () => _scanAndAppend(c),
        ) : null,
        filled: true, 
        fillColor: Colors.white, 
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)
      )
    )
  );
  
  Widget _buildRowInputs(TextEditingController c1, String l1, IconData i1, TextEditingController c2, String l2, IconData i2) => Row(children: [Expanded(child: _buildInput(c1, l1, i1)), const SizedBox(width: 12), Expanded(child: _buildInput(c2, l2, i2))]);
}