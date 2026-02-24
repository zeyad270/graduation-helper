  import 'dart:convert';
  import 'dart:io';
  import 'package:flutter/material.dart';
  import 'package:flutter/services.dart';
  import 'package:image_picker/image_picker.dart';
  import 'package:shared_preferences/shared_preferences.dart';

  import '../models/project_info.dart';
  import '../services/database_service.dart';
  import '../services/google_sheets_service.dart';
  import '../services/ocr_service.dart';

  // ─── Material You Color System ────────────────────────────────────────────────
  class _M3 {
    // Primary — deep indigo
    static const primary        = Color(0xFF4355B9);
    static const onPrimary      = Colors.white;
    static const primaryContainer    = Color(0xFFDDE1FF);
    static const onPrimaryContainer  = Color(0xFF00105C);

    // Secondary — slate blue
    static const secondary           = Color(0xFF5B5D72);
    static const secondaryContainer  = Color(0xFFE0E0F9);

    // Tertiary — teal
    static const tertiary            = Color(0xFF006874);
    static const tertiaryContainer   = Color(0xFF97F0FF);

    // Error
    static const error               = Color(0xFFBA1A1A);
    static const errorContainer      = Color(0xFFFFDAD6);

    // Success
    static const success             = Color(0xFF1B6B3A);
    static const successContainer    = Color(0xFFB6F2C8);

    // Warning
    static const warning             = Color(0xFF7C5800);
    static const warningContainer    = Color(0xFFFFDEA0);

    // Surface
    static const surface         = Color(0xFFFBFBFF);
    static const surfaceVariant  = Color(0xFFE4E1EC);
    static const background      = Color(0xFFF4F3FA);
    static const outline         = Color(0xFF777680);
    static const outlineVariant  = Color(0xFFC8C5D0);

    // On colors
    static const onSurface       = Color(0xFF1B1B1F);
    static const onSurfaceVariant= Color(0xFF46464F);
    static const onBackground    = Color(0xFF1B1B1F);

    // Elevation surfaces (tonal)
    static const surfaceL1 = Color(0xFFEFEDF8);
    static const surfaceL2 = Color(0xFFE9E7F5);
    static const surfaceL3 = Color(0xFFE4E1F1);

    // Shadows & states
    static const shadow = Color(0x1A000000);
  }

  // ─── App ──────────────────────────────────────────────────────────────────────
  class OCRHomePage extends StatefulWidget {
    const OCRHomePage({super.key});
    @override
    State<OCRHomePage> createState() => _OCRHomePageState();
  }

  class _OCRHomePageState extends State<OCRHomePage>
      with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
    @override
    bool get wantKeepAlive => true;

    // ── Navigation ──────────────────────────────────────────────────────────────
    late TabController _tabController;
    int _currentIndex = 0;

    // ── State ───────────────────────────────────────────────────────────────────
    final _picker = ImagePicker();
    final List<Map<String, dynamic>> _scannedDocs = [];
    bool   _isProcessing    = false;
    String _processingStep  = '';
    double _processingProgress = 0.0;

    List<ProjectInfo> _projects = [];
    int?  _editingProjectId;
    Map<String, dynamic> _lastExtracted = {};

    // Search & filter
    String _searchQuery = '';
    String _filterCategory = 'All';
    final _searchCtrl = TextEditingController();

    // ── Form Controllers ─────────────────────────────────────────────────────────
    final _titleCtrl      = TextEditingController();
    final _abstractCtrl   = TextEditingController();
    final _descCtrl       = TextEditingController();
    final _categoryCtrl   = TextEditingController();
    final _techCtrl       = TextEditingController();
    final _supervisorCtrl = TextEditingController();
    final _yearCtrl       = TextEditingController(text: DateTime.now().year.toString());
    final _keywordsCtrl   = TextEditingController();
    final _problemCtrl    = TextEditingController();
    final _solutionCtrl   = TextEditingController();
    final _objectivesCtrl = TextEditingController();
    final _studentEntryCtrl = TextEditingController();
    List<String> _studentNames = [];

    // ── Lifecycle ─────────────────────────────────────────────────────────────────
    @override
    void initState() {
      super.initState();
      _tabController = TabController(length: 3, vsync: this);
      _tabController.addListener(() {
        if (!_tabController.indexIsChanging) {
          setState(() => _currentIndex = _tabController.index);
        }
      });
      _loadProjects();
      _restoreDraft();
      for (final c in [_titleCtrl, _abstractCtrl, _descCtrl, _categoryCtrl,
            _techCtrl, _supervisorCtrl, _keywordsCtrl, _problemCtrl,
            _solutionCtrl, _objectivesCtrl]) {
        c.addListener(_saveDraft);
      }
    }

    @override
    void dispose() {
      _tabController.dispose();
      _searchCtrl.dispose();
      for (final c in [_titleCtrl, _abstractCtrl, _descCtrl, _categoryCtrl,
            _techCtrl, _supervisorCtrl, _yearCtrl, _keywordsCtrl, _problemCtrl,
            _solutionCtrl, _objectivesCtrl, _studentEntryCtrl]) {
        c.dispose();
      }
      super.dispose();
    }

    // ── Data ──────────────────────────────────────────────────────────────────────
    Future<void> _loadProjects() async {
      final list = await DatabaseService.getAllProjects();
      if (mounted) setState(() => _projects = list);
    }

    Future<void> _saveDraft() async {
      if (_editingProjectId != null) return;
      final prefs = await SharedPreferences.getInstance();
      // Truncate long fields to avoid SharedPreferences size limit
      String truncate(String s, [int max = 2000]) =>
          s.length > max ? s.substring(0, max) : s;
      await prefs.setString('draft_form', jsonEncode({
        'title':      _titleCtrl.text,
        'abstract':   truncate(_abstractCtrl.text),
        'desc':       truncate(_descCtrl.text),
        'cat':        _categoryCtrl.text,
        'tech':       _techCtrl.text,
        'sup':        _supervisorCtrl.text,
        'key':        _keywordsCtrl.text,
        'problem':    truncate(_problemCtrl.text),
        'solution':   truncate(_solutionCtrl.text),
        'objectives': truncate(_objectivesCtrl.text),
        'students':   _studentNames,
      }));
    }

    Future<void> _restoreDraft() async {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString('draft_form');
      if (s == null) return;
      try {
        final d = jsonDecode(s);
        setState(() {
          _titleCtrl.text      = d['title']      ?? '';
          _abstractCtrl.text   = d['abstract']   ?? '';
          _descCtrl.text       = d['desc']        ?? '';
          _categoryCtrl.text   = d['cat']         ?? '';
          _techCtrl.text       = d['tech']        ?? '';
          _supervisorCtrl.text = d['sup']         ?? '';
          _keywordsCtrl.text   = d['key']         ?? '';
          _problemCtrl.text    = d['problem']     ?? '';
          _solutionCtrl.text   = d['solution']    ?? '';
          _objectivesCtrl.text = d['objectives']  ?? '';
          if (d['students'] != null) {
            _studentNames = List<String>.from(d['students']);
          }
        });
        if (_titleCtrl.text.isNotEmpty) {
          _showSnack('Draft restored', type: _SnackType.success);
        }
      } catch (_) {}
    }

    Future<void> _clearDraft() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('draft_form');
    }

    // ── Image Picking ─────────────────────────────────────────────────────────────
    Future<void> _pickDocuments(ImageSource source) async {
      try {
        if (source == ImageSource.gallery) {
          final images = await _picker.pickMultiImage(imageQuality: 90);
          for (final img in images) await _addImage(img);
        } else {
          final img = await _picker.pickImage(source: ImageSource.camera, imageQuality: 90);
          if (img != null) await _addImage(img);
        }
      } catch (e) {
        _showSnack('Could not pick image: $e', type: _SnackType.error);
      }
    }

    Future<void> _addImage(XFile img) async {
      // Save image to app documents dir so it persists if cache is cleared
      final appDir  = Directory.systemTemp;
      final fileName = 'gradocr_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final saved   = await File(img.path).copy('${appDir.path}/$fileName');

      setState(() {
        _scannedDocs.add({
          'image':     XFile(saved.path),
          'rawText':   '',
          'label':     'Page ${_scannedDocs.length + 1}',
          'isLoading': false,
        });
      });
      _saveDraft();
    }

    void _removeDoc(int i) {
      setState(() => _scannedDocs.removeAt(i));
      _saveDraft();
    }

    // ── AI Extract ────────────────────────────────────────────────────────────────
    Future<void> _aiExtractAll() async {
      if (_scannedDocs.isEmpty) {
        _showSnack('Add document pages first', type: _SnackType.warning);
        return;
      }

      setState(() {
        _isProcessing     = true;
        _processingStep   = 'Preparing...';
        _processingProgress = 0.05;
      });

      try {
        final imagePaths = _scannedDocs
            .where((d) => d['image'] != null)
            .map((d) => (d['image'] as XFile).path)
            .toList();
        final rawTexts = _scannedDocs
            .map((d) => d['rawText'] as String)
            .where((t) => t.isNotEmpty)
            .toList();

        final fields = await OcrService.extractFromAll(
          imagePaths: imagePaths,
          rawTexts:   rawTexts,
          onProgress: (step, progress) {
            if (mounted) setState(() {
              _processingStep     = step;
              _processingProgress = progress;
            });
          },
        );

        setState(() {
          _processingStep     = 'Filling form...';
          _processingProgress = 0.97;
        });

        await Future.delayed(const Duration(milliseconds: 150));
        _fillForm(fields);

        // Count extracted fields
        final count = _allKeys
            .where((k) => (fields[k]?['value'] as String? ?? '').isNotEmpty)
            .length;
        _showSnack('Extracted $count of ${_allKeys.length} fields', type: _SnackType.success);
      } catch (e) {
        _showSnack('Extraction failed: $e', type: _SnackType.error);
      } finally {
        if (mounted) setState(() {
          _isProcessing       = false;
          _processingStep     = '';
          _processingProgress = 0;
        });
      }
    }

    void _fillForm(Map<String, dynamic> fields) {
      String v(String key) {
        final x = fields[key];
        if (x == null) return '';
        if (x is String) return x;
        if (x is Map) return x['value']?.toString() ?? '';
        return '';
      }
      setState(() {
        _titleCtrl.text      = v('title');
        _abstractCtrl.text   = v('abstract');
        _descCtrl.text       = v('description');
        _supervisorCtrl.text = v('supervisor');
        _yearCtrl.text       = v('year').isNotEmpty ? v('year') : DateTime.now().year.toString();
        _techCtrl.text       = v('technologies');
        _keywordsCtrl.text   = v('keywords');
        _categoryCtrl.text   = v('category');
        _problemCtrl.text    = v('problem');
        _solutionCtrl.text   = v('solution');
        _objectivesCtrl.text = v('objectives');
        final raw = v('students');
        if (raw.isNotEmpty) {
          _studentNames = raw.split(RegExp(r'[,;|]'))
              .map((e) => e.trim())
              .where((e) => e.length > 2)
              .toList();
        }
        _lastExtracted = fields;
      });
      _saveDraft();
    }

    Future<void> _reExtractField(TextEditingController ctrl, String key) async {
      final imagePaths = _scannedDocs
          .where((d) => d['image'] != null)
          .map((d) => (d['image'] as XFile).path)
          .toList();
      final allText = _scannedDocs
          .map((d) => d['rawText'] as String)
          .where((t) => t.isNotEmpty)
          .join('\n\n');

      if (imagePaths.isEmpty && allText.isEmpty) {
        _showSnack('No pages scanned yet', type: _SnackType.warning);
        return;
      }

      _showSnack('Re-extracting $key...', type: _SnackType.info);

      final value = await OcrService.extractSingleField(
        key,
        imagePaths:   imagePaths,
        fallbackText: allText,
      );

   if (value.isNotEmpty) {
  setState(() {
    final existing = ctrl.text.trim();
    ctrl.text = existing.isEmpty ? value : '$existing\n$value';
  });
  _saveDraft();
  _showSnack('$key appended!', type: _SnackType.success);
    }
    }

    Future<void> _scanFieldFromImage(
        TextEditingController ctrl, String key, ImageSource source) async {
      try {
        final XFile? picked = source == ImageSource.gallery
            ? (await _picker.pickMultiImage()).firstOrNull
            : await _picker.pickImage(source: ImageSource.camera);
        if (picked == null) return;

        _showSnack('Analyzing image for $key...', type: _SnackType.info);

        final value = await OcrService.smartScanForField(
          fieldName: key,
          imagePath: picked.path,
        );

       if (value.isNotEmpty) {
  setState(() {
    final existing = ctrl.text.trim();
    ctrl.text = existing.isEmpty ? value : '$existing\n$value';
  });
  _saveDraft();
  _showSnack('$key appended!', type: _SnackType.success);
       }
      } catch (e) {
        _showSnack('Error: $e', type: _SnackType.error);
      }
    }

    // ── Save / Edit ───────────────────────────────────────────────────────────────
    void _startEditing(ProjectInfo p) {
      setState(() {
        _editingProjectId    = p.id;
        _titleCtrl.text      = p.title;
        _abstractCtrl.text   = p.abstractText;
        _descCtrl.text       = p.description;
        _categoryCtrl.text   = p.category;
        _techCtrl.text       = p.technologies.join(', ');
        _keywordsCtrl.text   = p.extractedKeywords.join(', ');
        _studentNames        = List.from(p.studentNames);
        _supervisorCtrl.text = p.supervisorName;
        _yearCtrl.text       = p.year;
        _problemCtrl.text    = p.problem;
        _solutionCtrl.text   = p.solution;
        _objectivesCtrl.text = p.objectives;
        _scannedDocs.clear();
        _tabController.animateTo(0);
      });
    }

    Future<void> _saveProject() async {
      if (_titleCtrl.text.trim().isEmpty) {
        _showSnack('Project title is required', type: _SnackType.error);
        return;
      }
      final raw = _scannedDocs.map((d) => d['rawText'] as String).join('\n\n');
      final project = ProjectInfo(
        id:                _editingProjectId,
        title:             _titleCtrl.text.trim(),
        abstractText:      _abstractCtrl.text.trim(),
        description:       _descCtrl.text.trim(),
        category:          _categoryCtrl.text.trim(),
        technologies:      _techCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        extractedKeywords: _keywordsCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        studentNames:      _studentNames,
        supervisorName:    _supervisorCtrl.text.trim(),
        year:              _yearCtrl.text.trim(),
        rawOcrText:        raw,
        isSynced:          false,
        problem:           _problemCtrl.text.trim(),
        solution:          _solutionCtrl.text.trim(),
        objectives:        _objectivesCtrl.text.trim(),
      );
      if (_editingProjectId != null) {
        await DatabaseService.updateProject(project);
        _showSnack('Project updated', type: _SnackType.success);
      } else {
        await DatabaseService.insertProject(project);
        _showSnack('Project saved', type: _SnackType.success);
      }
      _clearForm();
      _loadProjects();
      _tabController.animateTo(2);
    }

    void _clearForm() {
      _clearDraft();
      setState(() {
        _editingProjectId = null;
        _scannedDocs.clear();
        _lastExtracted = {};
        for (final c in [_titleCtrl, _abstractCtrl, _descCtrl, _categoryCtrl,
              _techCtrl, _supervisorCtrl, _keywordsCtrl, _problemCtrl,
              _solutionCtrl, _objectivesCtrl, _studentEntryCtrl]) {
          c.clear();
        }
        _studentNames.clear();
        _yearCtrl.text = DateTime.now().year.toString();
      });
    }

    // ── Sync ──────────────────────────────────────────────────────────────────────
    Future<void> _syncAll() async {
      final unsynced = _projects.where((p) => !p.isSynced).toList();
      if (unsynced.isEmpty) return;

      _showSnack('Syncing ${unsynced.length} project(s)...', type: _SnackType.info);
      int ok = 0;

      for (final p in unsynced) {
        bool success = false;
        for (int attempt = 1; attempt <= 3; attempt++) {
          if (attempt > 1) await Future.delayed(Duration(seconds: attempt));
          success = await GoogleSheetsService.uploadProject(p);
          if (success) break;
        }
        if (success) {
          await DatabaseService.updateProject(p.copyWith(isSynced: true));
          ok++;
        }
      }

      _loadProjects();
      _showSnack(
        ok == unsynced.length ? 'All synced!' : 'Synced $ok / ${unsynced.length}',
        type: ok == unsynced.length ? _SnackType.success : _SnackType.warning,
      );
    }

    Future<void> _syncSingle(ProjectInfo p) async {
      _showSnack('Syncing...', type: _SnackType.info);
      bool success = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        if (attempt > 1) await Future.delayed(Duration(seconds: attempt));
        success = await GoogleSheetsService.uploadProject(p);
        if (success) break;
      }
      if (success) {
        await DatabaseService.updateProject(p.copyWith(isSynced: true));
        _loadProjects();
        _showSnack('Synced!', type: _SnackType.success);
      } else {
        _showSnack('Sync failed — check connection', type: _SnackType.error);
      }
    }

    // ── UI Helpers ────────────────────────────────────────────────────────────────
    void _showSnack(String msg, {required _SnackType type}) {
      if (!mounted) return;
      final colors = {
        _SnackType.success: _M3.success,
        _SnackType.error:   _M3.error,
        _SnackType.warning: _M3.warning,
        _SnackType.info:    _M3.primary,
      };
      final icons = {
        _SnackType.success: Icons.check_circle_rounded,
        _SnackType.error:   Icons.error_rounded,
        _SnackType.warning: Icons.warning_rounded,
        _SnackType.info:    Icons.info_rounded,
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          Icon(icons[type], color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: const TextStyle(color: Colors.white, fontSize: 14))),
        ]),
        backgroundColor: colors[type],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.all(14),
        duration: const Duration(seconds: 3),
      ));
    }

    Future<bool> _confirm(String title, String body) async {
      return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              backgroundColor: _M3.surface,
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              content: Text(body, style: TextStyle(color: _M3.onSurfaceVariant)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _M3.error),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ) ??
          false;
    }

    void _showFieldScanPicker(TextEditingController ctrl, String key) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _FieldScanSheet(
          fieldName: key,
          onCamera:  () { Navigator.pop(ctx); _scanFieldFromImage(ctrl, key, ImageSource.camera); },
          onGallery: () { Navigator.pop(ctx); _scanFieldFromImage(ctrl, key, ImageSource.gallery); },
        ),
      );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BUILD
    // ═══════════════════════════════════════════════════════════════════════════

    @override
    Widget build(BuildContext context) {
      super.build(context);
      final isEditing     = _editingProjectId != null;
      final unsyncedCount = _projects.where((p) => !p.isSynced).length;

      return Theme(
        data: ThemeData(
          useMaterial3: true,
          colorScheme: const ColorScheme.light(
            primary:          _M3.primary,
            onPrimary:        _M3.onPrimary,
            primaryContainer: _M3.primaryContainer,
            secondary:        _M3.secondary,
            secondaryContainer: _M3.secondaryContainer,
            tertiary:         _M3.tertiary,
            tertiaryContainer:_M3.tertiaryContainer,
            error:            _M3.error,
            errorContainer:   _M3.errorContainer,
            surface:          _M3.surface,
            onSurface:        _M3.onSurface,
          ),
          fontFamily: 'Roboto',
        ),
        child: Scaffold(
          backgroundColor: _M3.background,
          appBar: _buildAppBar(isEditing, unsyncedCount),
          body: TabBarView(
            controller: _tabController,
            children: [
              _buildFormTab(isEditing),
              _buildDocsTab(),
              _buildProjectsTab(),
            ],
          ),
          floatingActionButton: _currentIndex == 2 && unsyncedCount > 0
              ? _buildSyncFab(unsyncedCount)
              : null,
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        ),
      );
    }

    // ─── AppBar ──────────────────────────────────────────────────────────────────
    PreferredSizeWidget _buildAppBar(bool isEditing, int unsyncedCount) {
      return AppBar(
        backgroundColor:  _M3.primary,
        foregroundColor:  _M3.onPrimary,
        elevation:        0,
        centerTitle:      false,
        title: Text(
          isEditing ? 'Edit Project' : 'InnoTrack Helper',
          style: const TextStyle(
            color: _M3.onPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 22,
            letterSpacing: -0.3,
          ),
        ),
        actions: [
          if (isEditing)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: _clearForm,
              tooltip: 'Cancel edit',
            )
          else if (_currentIndex == 0)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Clear form',
              onPressed: () async {
                if (await _confirm('Clear Form', 'Reset all fields?')) {
                  _clearForm();
                }
              },
            ),
          if (_currentIndex == 2)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Delete all projects',
              onPressed: () async {
                if (await _confirm('Delete All', 'This cannot be undone.')) {
                  for (final p in _projects) {
                    if (p.id != null) await DatabaseService.deleteProject(p.id!);
                  }
                  _loadProjects();
                  _showSnack('All projects deleted', type: _SnackType.success);
                }
              },
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(75),
          child: TabBar(
            controller:            _tabController,
            labelColor:            _M3.onPrimary,
            unselectedLabelColor:  _M3.onPrimary.withOpacity(0.55),
            indicatorColor:        _M3.onPrimary,
            indicatorWeight:       3,
            indicatorSize:         TabBarIndicatorSize.tab,
            labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
            tabs: [
              const Tab(icon: Icon(Icons.edit_note_rounded, size: 20), text: 'Form'),
              Tab(
                icon: _badge(Icons.document_scanner_rounded, _scannedDocs.length),
                text: 'Documents',
              ),
              Tab(
                icon: _badge(Icons.folder_rounded, _projects.length,
                    color: Colors.orange.shade300),
                text: 'Projects',
              ),
            ],
          ),
        ),
      );
    }

    Widget _badge(IconData icon, int count, {Color? color}) {
      return Stack(clipBehavior: Clip.none, children: [
        Icon(icon, size: 20),
        if (count > 0)
          Positioned(
            right: -8, top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: color ?? _M3.onPrimary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: color != null ? Colors.white : _M3.primary,
                ),
              ),
            ),
          ),
      ]);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TAB 1 — FORM
    // ═══════════════════════════════════════════════════════════════════════════

    Widget _buildFormTab(bool isEditing) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

          // Edit banner
          if (isEditing) ...[
            _editBanner(),
            const SizedBox(height: 16),
          ],

          // Documents + Extract section
          if (!isEditing) ...[
            _sectionHeader('Pages', Icons.document_scanner_rounded),
            _docsGrid(),
            const SizedBox(height: 12),
            _extractButton(),
            if (_lastExtracted.isNotEmpty) ...[
              const SizedBox(height: 12),
              _extractionSummaryCard(),
            ],
            const SizedBox(height: 24),
          ],

          // Project details
          _sectionHeader('Project Details', Icons.info_outline_rounded),
          _field(_titleCtrl, 'Project Title', Icons.title_rounded),
          const SizedBox(height: 12),
          _studentsField(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _field(_yearCtrl, 'Year', Icons.calendar_today_rounded,
                keyboardType: TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(child: _field(_categoryCtrl, 'Category', Icons.category_rounded)),
          ]),
          const SizedBox(height: 12),
          _field(_supervisorCtrl, 'Supervisor', Icons.school_rounded),
          const SizedBox(height: 12),
          _field(_techCtrl, 'Technologies', Icons.code_rounded, reExtractKey: 'technologies'),
          const SizedBox(height: 12),
          _field(_keywordsCtrl, 'Keywords', Icons.tag_rounded, reExtractKey: 'keywords'),

          const SizedBox(height: 20),
          _sectionHeader('Content', Icons.article_outlined),
          _field(_abstractCtrl,   'Abstract',    Icons.article_rounded,          maxLines: 5, reExtractKey: 'abstract'),
          const SizedBox(height: 12),
          _field(_descCtrl,       'Description', Icons.notes_rounded,            maxLines: 5, reExtractKey: 'description'),

          const SizedBox(height: 20),
          _sectionHeader('Problem & Solution', Icons.lightbulb_outline_rounded),
          _field(_problemCtrl,    'Problem Statement',  Icons.report_problem_rounded, maxLines: 4, reExtractKey: 'problem'),
          const SizedBox(height: 12),
          _field(_solutionCtrl,   'Proposed Solution',  Icons.check_circle_rounded,   maxLines: 4, reExtractKey: 'solution'),
          const SizedBox(height: 12),
          _field(_objectivesCtrl, 'Objectives',         Icons.flag_rounded,           maxLines: 4, reExtractKey: 'objectives'),

          const SizedBox(height: 28),
          _saveButton(isEditing),
          const SizedBox(height: 16),
        ]),
      );
    }

    Widget _editBanner() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _M3.warningContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Icon(Icons.edit_rounded, color: _M3.warning, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(
          'Editing: ${_titleCtrl.text}',
          style: TextStyle(color: _M3.warning, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        )),
        TextButton(
          onPressed: _clearForm,
          style: TextButton.styleFrom(foregroundColor: _M3.warning),
          child: const Text('Cancel'),
        ),
      ]),
    );

    Widget _sectionHeader(String label, IconData icon) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: _M3.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: _M3.onPrimaryContainer),
        ),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: _M3.onSurfaceVariant,
          letterSpacing: 0.1,
        )),
      ]),
    );

    // ── Documents Grid (in Form tab) ───────────────────────────────────────────
    Widget _docsGrid() {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Add buttons
        Row(children: [
          Expanded(child: _addPageBtn(
            Icons.camera_alt_rounded, 'Camera', _M3.primary,
            () => _pickDocuments(ImageSource.camera),
          )),
          const SizedBox(width: 10),
          Expanded(child: _addPageBtn(
            Icons.photo_library_rounded, 'Gallery', _M3.secondary,
            () => _pickDocuments(ImageSource.gallery),
          )),
        ]),

        if (_scannedDocs.isNotEmpty) ...[
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 8,
              mainAxisSpacing: 8, childAspectRatio: 0.75,
            ),
            itemCount: _scannedDocs.length,
            itemBuilder: (_, i) => _imageTile(i),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Column(children: [
              Icon(Icons.add_photo_alternate_outlined, size: 48, color: _M3.outlineVariant),
              const SizedBox(height: 8),
              Text('Add document pages to scan',
                  style: TextStyle(color: _M3.outline, fontSize: 13)),
            ])),
          ),
      ]);
    }

    Widget _addPageBtn(IconData icon, String label, Color color, VoidCallback onTap) {
      return Material(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: Colors.white, size: 17),
              ),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
    }

    Widget _imageTile(int i) {
      final doc = _scannedDocs[i];
      final img = doc['image'] as XFile?;

      return Stack(fit: StackFit.expand, children: [
        GestureDetector(
          onTap: img != null ? () => _previewImage(img, i) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: img != null
                ? Image.file(File(img.path), fit: BoxFit.cover)
                : Container(
                    decoration: BoxDecoration(
                      color: _M3.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.description_rounded,
                        color: _M3.onPrimaryContainer, size: 28),
                  ),
          ),
        ),
        // Page label
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black.withOpacity(0.65), Colors.transparent],
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                ),
              ),
              child: Text('Page ${i + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
        // Zoom
        if (img != null)
          Positioned(
            top: 5, left: 5,
            child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
              child: const Icon(Icons.zoom_in_rounded, color: Colors.white, size: 13),
            ),
          ),
        // Delete
        Positioned(
          top: 5, right: 5,
          child: GestureDetector(
            onTap: () => _removeDoc(i),
            child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: _M3.error, shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
              ),
              child: const Icon(Icons.close_rounded, color: Colors.white, size: 13),
            ),
          ),
        ),
      ]);
    }

    void _previewImage(XFile img, int index) {
      showDialog(
        context: context,
        barrierColor: Colors.black87,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: InteractiveViewer(
                minScale: 0.8, maxScale: 5.0,
                child: Image.file(File(img.path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 10, right: 10,
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 18),
                ),
              ),
            ),
            Positioned(
              bottom: 10, right: 10,
              child: GestureDetector(
                onTap: () { Navigator.pop(ctx); _removeDoc(index); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: _M3.error.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.delete_rounded, color: Colors.white, size: 15),
                    SizedBox(width: 5),
                    Text('Remove', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      );
    }

    // ── Extract Button ───────────────────────────────────────────────────────────
    Widget _extractButton() {
      final hasPages = _scannedDocs.any((d) => d['image'] != null);
      final count    = _scannedDocs.where((d) => d['image'] != null).length;

      return AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          gradient: hasPages
              ? const LinearGradient(
                  colors: [Color(0xFF4355B9), Color(0xFF6B52AE)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight)
              : null,
          color:         hasPages ? null : _M3.surfaceVariant,
          borderRadius:  BorderRadius.circular(20),
          boxShadow: hasPages
              ? [BoxShadow(
                  color: _M3.primary.withOpacity(0.35),
                  blurRadius: 18, offset: const Offset(0, 8))]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: (!hasPages || _isProcessing) ? null : _aiExtractAll,
            borderRadius: BorderRadius.circular(20),
            splashColor: Colors.white12,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              child: _isProcessing
                  ? Column(children: [
                      Row(children: [
                        const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white)),
                        const SizedBox(width: 14),
                        Expanded(child: Text(_processingStep,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                            overflow: TextOverflow.ellipsis)),
                        Text('${(_processingProgress * 100).round()}%',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: _processingProgress,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation(Colors.white),
                          minHeight: 4,
                        ),
                      ),
                    ])
                  : Row(children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(hasPages ? 0.18 : 0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.auto_awesome_rounded,
                            color: hasPages ? Colors.white : _M3.outline, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Extract All Fields',
                            style: TextStyle(
                              color: hasPages ? Colors.white : _M3.outline,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              letterSpacing: -0.2,
                            )),
                        const SizedBox(height: 2),
                        Text(
                          hasPages
                              ? '$count page${count != 1 ? "s" : ""} · Gemini Vision'
                              : 'Add pages above first',
                          style: TextStyle(
                            color: hasPages
                                ? Colors.white.withOpacity(0.72)
                                : _M3.outline.withOpacity(0.6),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ])),
                      if (hasPages)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text('GO',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 12,
                                  fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                        ),
                    ]),
            ),
          ),
        ),
      );
    }

    // ── Extraction Summary Card ──────────────────────────────────────────────────
    Widget _extractionSummaryCard() {
      String v(String key) {
        final x = _lastExtracted[key];
        if (x == null) return '';
        if (x is String) return x;
        if (x is Map) return x['value']?.toString() ?? '';
        return '';
      }

      double c(String key) {
        final x = _lastExtracted[key];
        if (x is Map) return (x['confidence'] as num?)?.toDouble() ?? 0.0;
        return 0.0;
      }

      final found = _allKeys.where((k) => v(k).isNotEmpty).toList();

      return Container(
        decoration: BoxDecoration(
          color: _M3.successContainer.withOpacity(0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _M3.success.withOpacity(0.25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                    color: _M3.success, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(
                'Extracted ${found.length} of ${_allKeys.length} fields',
                style: TextStyle(
                    color: _M3.success, fontWeight: FontWeight.w700, fontSize: 14),
              )),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: _M3.success, borderRadius: BorderRadius.circular(20)),
                child: Text('${found.length}/${_allKeys.length}',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),

          // Field chips
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 6, runSpacing: 6,
              children: _allKeys.map((key) {
                final filled = v(key).isNotEmpty;
                final conf   = c(key);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: filled
                        ? _M3.success.withOpacity(0.12)
                        : _M3.surfaceVariant.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: filled
                          ? _M3.success.withOpacity(0.4)
                          : _M3.outlineVariant,
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                      filled ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 12,
                      color: filled ? _M3.success : _M3.outline,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _fieldLabels[key] ?? key,
                      style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600,
                        color: filled ? _M3.success : _M3.outline,
                      ),
                    ),
                    if (filled && conf > 0) ...[
                      const SizedBox(width: 4),
                      Text(
                        '${(conf * 100).round()}%',
                        style: TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w700,
                          color: _M3.success.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ]),
                );
              }).toList(),
            ),
          ),

          // Key previews
          if (v('title').isNotEmpty || v('supervisor').isNotEmpty) ...[
            Divider(height: 1, color: _M3.success.withOpacity(0.2)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Column(children: [
                if (v('title').isNotEmpty)
                  _previewRow('Title', v('title'), Icons.title_rounded),
                if (v('supervisor').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _previewRow('Supervisor', v('supervisor'), Icons.school_rounded),
                ],
                if (v('abstract').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _previewRow('Abstract', v('abstract'), Icons.article_rounded, max: 110),
                ],
              ]),
            ),
          ],
        ]),
      );
    }

    Widget _previewRow(String label, String val, IconData icon, {int max = 60}) {
      final display = val.length > max ? '${val.substring(0, max)}...' : val;
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: _M3.success.withOpacity(0.8)),
        const SizedBox(width: 8),
        Expanded(child: RichText(text: TextSpan(children: [
          TextSpan(text: '$label: ',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                  color: _M3.success.withOpacity(0.9))),
          TextSpan(text: display,
              style: TextStyle(fontSize: 12, color: _M3.onSurfaceVariant)),
        ]))),
      ]);
    }

    // ── Form Fields ──────────────────────────────────────────────────────────────
    Widget _field(
      TextEditingController ctrl,
      String label,
      IconData icon, {
      int maxLines          = 1,
      TextInputType keyboardType = TextInputType.text,
      String? reExtractKey,
    }) {
      return TextField(
        controller:   ctrl,
        maxLines:     maxLines,
        keyboardType: keyboardType,
        style: TextStyle(color: _M3.onSurface, fontSize: 14),
        decoration: InputDecoration(
          labelText:  label,
          labelStyle: TextStyle(color: _M3.onSurfaceVariant, fontSize: 14),
          prefixIcon: Icon(icon, size: 20, color: _M3.onSurfaceVariant),
          suffixIcon: reExtractKey != null
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  // ✨ re-extract from scanned pages
                  IconButton(
                    icon: Icon(Icons.auto_awesome_rounded, size: 18, color: _M3.primary),
                    tooltip: 'Re-extract from scanned pages',
                    onPressed: () => _reExtractField(ctrl, reExtractKey),
                  ),
                  // 📷 scan new photo for this field
                  IconButton(
                    icon: const Icon(Icons.add_a_photo_rounded, size: 18,
                        color: Color(0xFF6B52AE)),
                    tooltip: 'Scan a photo for this field',
                    onPressed: () => _showFieldScanPicker(ctrl, reExtractKey),
                  ),
                ])
              : null,
          filled:     true,
          fillColor:  _M3.surface,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: _M3.outlineVariant)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: _M3.outlineVariant)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: _M3.primary, width: 2)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      );
    }

    Widget _studentsField() {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: TextField(
            controller: _studentEntryCtrl,
            style: TextStyle(color: _M3.onSurface, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Add Student Name',
              labelStyle: TextStyle(color: _M3.onSurfaceVariant),
              prefixIcon: Icon(Icons.person_add_rounded, size: 20, color: _M3.onSurfaceVariant),
              filled: true, fillColor: _M3.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: _M3.outlineVariant)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: _M3.outlineVariant)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: _M3.primary, width: 2)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            onSubmitted: (_) => _addStudent(),
          )),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _addStudent,
            style: FilledButton.styleFrom(
              backgroundColor: _M3.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              minimumSize: const Size(48, 52),
              padding: EdgeInsets.zero,
            ),
            child: const Icon(Icons.add_rounded, size: 22),
          ),
        ]),
        if (_studentNames.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: _studentNames.map((name) {
            return InputChip(
              label: Text(name, style: const TextStyle(fontSize: 12)),
              onDeleted: () => setState(() { _studentNames.remove(name); _saveDraft(); }),
              backgroundColor: _M3.primaryContainer,
              side: BorderSide.none,
              labelStyle: TextStyle(color: _M3.onPrimaryContainer, fontWeight: FontWeight.w500),
              deleteIconColor: _M3.onPrimaryContainer,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          }).toList()),
        ],
      ]);
    }

    Widget _saveButton(bool isEditing) => SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: _saveProject,
        style: FilledButton.styleFrom(
          backgroundColor: isEditing ? _M3.warning : _M3.success,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        icon: Icon(isEditing ? Icons.update_rounded : Icons.save_rounded, size: 20),
        label: Text(
          isEditing ? 'Update Project' : 'Save Project',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      ),
    );

    void _addStudent() {
      final name = _studentEntryCtrl.text.trim();
      if (name.isNotEmpty && !_studentNames.contains(name)) {
        setState(() { _studentNames.add(name); _studentEntryCtrl.clear(); });
        _saveDraft();
      }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TAB 2 — DOCUMENTS
    // ═══════════════════════════════════════════════════════════════════════════

    Widget _buildDocsTab() {
      if (_scannedDocs.isEmpty) {
        return _emptyState(Icons.document_scanner_rounded,
            'No pages yet', 'Add images in the Form tab');
      }

      String v(String key) {
        final x = _lastExtracted[key];
        if (x == null) return '';
        if (x is String) return x;
        if (x is Map) return x['value']?.toString() ?? '';
        return '';
      }

      final extracted = _allKeys.where((k) => v(k).isNotEmpty).toList();

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

          // Page strip
          Text('PAGES',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800,
                  color: _M3.onSurfaceVariant, letterSpacing: 1.5)),
          const SizedBox(height: 10),
          SizedBox(
            height: 170,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _scannedDocs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final doc = _scannedDocs[i];
                final img = doc['image'] as XFile?;
                return GestureDetector(
                  onTap: img != null ? () => _previewImage(img, i) : null,
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: img != null
                          ? Image.file(File(img.path),
                              width: 120, height: 170, fit: BoxFit.cover)
                          : Container(
                              width: 120, height: 170,
                              decoration: BoxDecoration(
                                  color: _M3.primaryContainer,
                                  borderRadius: BorderRadius.circular(14)),
                              child: Icon(Icons.description_rounded,
                                  color: _M3.onPrimaryContainer, size: 32)),
                    ),
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(14)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          color: Colors.black54,
                          child: Text('Page ${i + 1}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                    if (img != null)
                      Positioned(
                        top: 6, right: 6,
                        child: Container(
                          width: 24, height: 24,
                          decoration: BoxDecoration(
                              color: Colors.black45, shape: BoxShape.circle),
                          child: const Icon(Icons.zoom_in_rounded,
                              color: Colors.white, size: 14),
                        ),
                      ),
                  ]),
                );
              },
            ),
          ),

          const SizedBox(height: 24),

          // Extracted data
          Row(children: [
            Text('EXTRACTED DATA',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800,
                    color: _M3.onSurfaceVariant, letterSpacing: 1.5)),
            const Spacer(),
            if (_lastExtracted.isEmpty)
              _chip('Not extracted yet', _M3.warningContainer, _M3.warning)
            else
              _chip('${extracted.length}/${_allKeys.length} fields',
                  _M3.successContainer, _M3.success),
          ]),
          const SizedBox(height: 12),

          if (_lastExtracted.isEmpty)
            _emptyExtractCard()
          else
            ..._allKeys.where((k) => v(k).isNotEmpty).map((key) =>
                _extractedFieldCard(
                  label: _fieldLabels[key] ?? key,
                  value: v(key),
                  icon: _fieldIcons[key] ?? Icons.label_rounded,
                  confidence: () {
                    final x = _lastExtracted[key];
                    if (x is Map) return (x['confidence'] as num?)?.toDouble() ?? 0.0;
                    return 0.0;
                  }(),
                ),
            ),

          const SizedBox(height: 80),
        ]),
      );
    }

    Widget _chip(String label, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(label, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w700)),
    );

    Widget _emptyExtractCard() => Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _M3.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _M3.outlineVariant),
      ),
      child: Column(children: [
        Icon(Icons.auto_awesome_outlined, size: 40, color: _M3.outlineVariant),
        const SizedBox(height: 12),
        Text('Tap "Extract All Fields" in the Form tab',
            style: TextStyle(color: _M3.outline, fontSize: 13),
            textAlign: TextAlign.center),
      ]),
    );

    Widget _extractedFieldCard({
      required String label, required String value,
      required IconData icon, required double confidence,
    }) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _M3.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _M3.outlineVariant),
          boxShadow: [BoxShadow(color: _M3.shadow, blurRadius: 4, offset: const Offset(0, 1))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                    color: _M3.primaryContainer, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 16, color: _M3.onPrimaryContainer),
              ),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const Spacer(),
              if (confidence > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: confidence > 0.8
                        ? _M3.successContainer
                        : confidence > 0.5
                            ? _M3.warningContainer
                            : _M3.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${(confidence * 100).round()}%',
                    style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w800,
                      color: confidence > 0.8 ? _M3.success
                          : confidence > 0.5 ? _M3.warning : _M3.error,
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              IconButton(
                icon: Icon(Icons.copy_rounded, size: 16, color: _M3.onSurfaceVariant),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  _showSnack('Copied $label', type: _SnackType.success);
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ]),
          ),
          Divider(height: 1, color: _M3.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: SelectableText(value,
                style: TextStyle(fontSize: 13, height: 1.65, color: _M3.onSurface)),
          ),
        ]),
      );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TAB 3 — PROJECTS
    // ═══════════════════════════════════════════════════════════════════════════

    Widget _buildProjectsTab() {
      final categories = ['All', ..._projects.map((p) => p.category)
          .where((c) => c.isNotEmpty).toSet().toList()..sort()];

      final filtered = _projects.where((p) {
        final q = _searchQuery.toLowerCase();
        final matchSearch = q.isEmpty ||
            p.title.toLowerCase().contains(q) ||
            p.supervisorName.toLowerCase().contains(q) ||
            p.studentNames.any((s) => s.toLowerCase().contains(q));
        final matchCat = _filterCategory == 'All' || p.category == _filterCategory;
        return matchSearch && matchCat;
      }).toList();

      return Column(children: [
        // Search + filter bar
        Container(
          color: _M3.surface,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(children: [
            // Search
            TextField(
              controller: _searchCtrl,
              onChanged: (q) => setState(() => _searchQuery = q),
              style: TextStyle(fontSize: 14, color: _M3.onSurface),
              decoration: InputDecoration(
                hintText: 'Search projects...',
                hintStyle: TextStyle(color: _M3.outline),
                prefixIcon: Icon(Icons.search_rounded, color: _M3.outline),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear_rounded, color: _M3.outline),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: _M3.surfaceL1,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            const SizedBox(height: 10),
            // Category filter chips
            if (categories.length > 1)
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: categories.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final cat      = categories[i];
                    final selected = _filterCategory == cat;
                    return FilterChip(
                      label: Text(cat, style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: selected ? _M3.onPrimaryContainer : _M3.onSurfaceVariant)),
                      selected: selected,
                      onSelected: (_) => setState(() => _filterCategory = cat),
                      selectedColor: _M3.primaryContainer,
                      backgroundColor: _M3.surfaceVariant,
                      side: BorderSide.none,
                      showCheckmark: false,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    );
                  },
                ),
              ),
            const SizedBox(height: 10),
          ]),
        ),

        // Stats row
        if (_projects.isNotEmpty)
          Container(
            color: _M3.surface,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              _statPill('${_projects.length}', 'Total', _M3.primaryContainer, _M3.onPrimaryContainer),
              const SizedBox(width: 8),
              _statPill(
                '${_projects.where((p) => p.isSynced).length}',
                'Synced', _M3.successContainer, _M3.success),
              const SizedBox(width: 8),
              _statPill(
                '${_projects.where((p) => !p.isSynced).length}',
                'Pending', _M3.warningContainer, _M3.warning),
            ]),
          ),

        Divider(height: 1, color: _M3.outlineVariant),

        // List
        Expanded(child: filtered.isEmpty
            ? _emptyState(Icons.folder_off_rounded,
                _searchQuery.isNotEmpty ? 'No results found' : 'No projects yet',
                _searchQuery.isNotEmpty
                    ? 'Try a different search term'
                    : 'Fill in the form and tap Save')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final p = filtered[i];
                  return Dismissible(
                    key: Key('proj_${p.id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      decoration: BoxDecoration(
                          color: _M3.errorContainer,
                          borderRadius: BorderRadius.circular(20)),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: Icon(Icons.delete_rounded, color: _M3.error),
                    ),
                    confirmDismiss: (_) => _confirm('Delete Project?', 'This cannot be undone.'),
                    onDismissed: (_) async {
                      await DatabaseService.deleteProject(p.id!);
                      _loadProjects();
                    },
                    child: _projectCard(p),
                  );
                },
              )),
      ]);
    }

    Widget _statPill(String count, String label, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(count, style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w800, color: fg)),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 11, color: fg.withOpacity(0.8))),
      ]),
    );

    Widget _projectCard(ProjectInfo p) => Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: _M3.outlineVariant)),
      color: _M3.surface,
      child: InkWell(
        onTap: () => _startEditing(p),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Status row
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: p.isSynced ? _M3.successContainer : _M3.warningContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    p.isSynced ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                    size: 12,
                    color: p.isSynced ? _M3.success : _M3.warning,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    p.isSynced ? 'Synced' : 'Local',
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: p.isSynced ? _M3.success : _M3.warning,
                    ),
                  ),
                ]),
              ),
              if (p.year.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(p.year, style: TextStyle(color: _M3.outline, fontSize: 12)),
              ],
              const Spacer(),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: _M3.outline, size: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                color: _M3.surface,
                onSelected: (val) async {
                  if (val == 'edit')   _startEditing(p);
                  if (val == 'sync')   _syncSingle(p);
                  if (val == 'delete') {
                    if (await _confirm('Delete?', 'Cannot be undone.')) {
                      await DatabaseService.deleteProject(p.id!);
                      _loadProjects();
                    }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit',
                      child: Row(children: [
                        Icon(Icons.edit_rounded, size: 18), SizedBox(width: 10), Text('Edit'),
                      ])),
                  if (!p.isSynced)
                    const PopupMenuItem(value: 'sync',
                        child: Row(children: [
                          Icon(Icons.cloud_upload_rounded, size: 18), SizedBox(width: 10), Text('Sync'),
                        ])),
                  PopupMenuItem(value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete_rounded, size: 18, color: _M3.error),
                        const SizedBox(width: 10),
                        Text('Delete', style: TextStyle(color: _M3.error)),
                      ])),
                ],
              ),
            ]),

            const SizedBox(height: 10),
            Text(p.title, style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, height: 1.3)),

            if (p.supervisorName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                Icon(Icons.school_rounded, size: 14, color: _M3.outline),
                const SizedBox(width: 5),
                Text(p.supervisorName, style: TextStyle(
                    color: _M3.onSurfaceVariant, fontSize: 13)),
              ]),
            ],

            if (p.category.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.category_rounded, size: 14, color: _M3.outline),
                const SizedBox(width: 5),
                Text(p.category, style: TextStyle(
                    color: _M3.onSurfaceVariant, fontSize: 13)),
              ]),
            ],

            if (p.problem.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _M3.warningContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.report_problem_rounded, size: 13, color: _M3.warning),
                  const SizedBox(width: 6),
                  Expanded(child: Text(
                    p.problem.length > 90
                        ? '${p.problem.substring(0, 90)}...'
                        : p.problem,
                    style: TextStyle(color: _M3.onSurfaceVariant, fontSize: 12, height: 1.4),
                  )),
                ]),
              ),
            ],

            if (p.studentNames.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 4,
                children: p.studentNames.take(3).map((s) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: _M3.secondaryContainer,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(s, style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w500,
                      color: _M3.secondary)),
                )).toList()),
              if (p.studentNames.length > 3)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('+${p.studentNames.length - 3} more',
                      style: TextStyle(fontSize: 11, color: _M3.outline)),
                ),
            ],
          ]),
        ),
      ),
    );

    Widget _buildSyncFab(int count) => FloatingActionButton.extended(
      onPressed: _syncAll,
      backgroundColor: _M3.primary,
      foregroundColor: Colors.white,
      elevation: 4,
      icon: const Icon(Icons.cloud_upload_rounded),
      label: Text('Sync All ($count)',
          style: const TextStyle(fontWeight: FontWeight.w700)),
    );

    Widget _emptyState(IconData icon, String title, String subtitle) =>
        Center(child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 88, height: 88,
              decoration: BoxDecoration(
                  color: _M3.primaryContainer, borderRadius: BorderRadius.circular(24)),
              child: Icon(icon, size: 40, color: _M3.onPrimaryContainer),
            ),
            const SizedBox(height: 20),
            Text(title, style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(
                fontSize: 13, color: _M3.onSurfaceVariant), textAlign: TextAlign.center),
          ]),
        ));

    // ── Constants ────────────────────────────────────────────────────────────────
    static const List<String> _allKeys = [
      'title', 'students', 'supervisor', 'year', 'abstract',
      'technologies', 'description', 'keywords', 'category',
      'problem', 'solution', 'objectives',
    ];

    static const Map<String, String> _fieldLabels = {
      'title': 'Title', 'students': 'Students', 'supervisor': 'Supervisor',
      'year': 'Year', 'abstract': 'Abstract', 'technologies': 'Technologies',
      'description': 'Description', 'keywords': 'Keywords', 'category': 'Category',
      'problem': 'Problem', 'solution': 'Solution', 'objectives': 'Objectives',
    };

    static const Map<String, IconData> _fieldIcons = {
      'title':        Icons.title_rounded,
      'students':     Icons.people_rounded,
      'supervisor':   Icons.school_rounded,
      'year':         Icons.calendar_today_rounded,
      'abstract':     Icons.article_rounded,
      'technologies': Icons.code_rounded,
      'description':  Icons.notes_rounded,
      'keywords':     Icons.tag_rounded,
      'category':     Icons.category_rounded,
      'problem':      Icons.report_problem_rounded,
      'solution':     Icons.check_circle_rounded,
      'objectives':   Icons.flag_rounded,
    };
  }

  // ─── Field Scan Bottom Sheet ─────────────────────────────────────────────────
  class _FieldScanSheet extends StatelessWidget {
    final String fieldName;
    final VoidCallback onCamera;
    final VoidCallback onGallery;

    const _FieldScanSheet({
      required this.fieldName,
      required this.onCamera,
      required this.onGallery,
    });

    @override
    Widget build(BuildContext context) {
      return Container(
        decoration: const BoxDecoration(
          color: _M3.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4,
              decoration: BoxDecoration(
                  color: _M3.outlineVariant, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          Text('Scan for ${fieldName[0].toUpperCase()}${fieldName.substring(1)}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          const SizedBox(height: 6),
          Text(
            'Gemini will read the image and intelligently fill this field',
            style: TextStyle(color: _M3.onSurfaceVariant, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: _scanBtn(
              context, Icons.camera_alt_rounded, 'Camera', _M3.primary, onCamera)),
            const SizedBox(width: 12),
            Expanded(child: _scanBtn(
              context, Icons.photo_library_rounded, 'Gallery',
              const Color(0xFF6B52AE), onGallery)),
          ]),
        ]),
      );
    }

    Widget _scanBtn(BuildContext ctx, IconData icon, String label, Color color, VoidCallback onTap) {
      return Material(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Column(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(height: 8),
              Text(label, style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
    }
  }

  enum _SnackType { success, error, warning, info }