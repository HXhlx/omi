import 'package:flutter/material.dart';

import 'package:omi/backend/http/api/provider_settings.dart' as api;
import 'package:omi/local_backend/on_device_models.dart' as models;
import 'package:omi/pages/settings/transcription/transcription_fields.dart';
import 'package:omi/ui/ui.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// Provider cards: one expandable card per channel listing every service it
/// offers (speech-to-text, text-to-speech, language model, realtime), each with
/// a dropdown whose default is the newest model. Below the cards, a unified
/// channel section picks the primary provider per service and only lists
/// activated providers.
///
/// All state lives on the local backend (`/v1/provider/*`), which routes every
/// LLM/STT/TTS call through the selected card.
class ProviderCardsPage extends StatefulWidget {
  const ProviderCardsPage({super.key, this.apiClient});

  /// Test seam.
  final api.ProviderApi? apiClient;

  @override
  State<ProviderCardsPage> createState() => _ProviderCardsPageState();
}

/// Services shown as rows inside a card, in display order.
const List<String> _cardCapabilities = ['asr', 'tts', 'llm', 'realtime', 'vision', 'video', 'embed'];

/// Services the unified channel section routes. Vision follows the LLM and
/// video is not routed by this page, so neither is offered here. Embedding is
/// internal to memory search — no user-facing route chain.
const List<String> _routedCapabilities = ['asr', 'tts', 'llm', 'realtime'];

class _ProviderCardsPageState extends State<ProviderCardsPage> {
  late final api.ProviderApi _api = widget.apiClient ?? const api.ProviderApi();

  bool _loading = true;
  String? _error;
  List<api.ProviderChannel> _catalog = const [];
  Map<String, List<String>> _active = const {};

  /// Draft settings being edited. Saved on demand.
  api.ProviderSettings? _draft;

  /// Per-card key input controllers, created lazily.
  final Map<String, TextEditingController> _keyControllers = {};

  /// Cards whose services are expanded.
  final Set<String> _expanded = {};

  /// `requiresModel` cards the user reported downloaded to the backend
  /// (mirror of `provider_model:<id>` rows).
  final Set<String> _modelReady = {};

  /// Card id -> current download fraction 0–1 (only while in flight).
  final Map<String, double> _downloading = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _keyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  api.ProviderChannel? _channelOf(String id) {
    for (final c in _catalog) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await _api.getCatalog();
      final settings = await _api.getSettings();
      final active = await _api.getActive();
      if (!mounted) return;
      // On-device model cards: already-downloaded check is local (files on
      // disk), so the page reflects reality even before the backend row.
      final ready = <String>{};
      for (final c in catalog.where((c) => c.requiresModel)) {
        if (await models.isOnDeviceModelDownloaded(c.id)) ready.add(c.id);
      }
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _draft = settings;
        _active = active;
        _modelReady..clear()..addAll(ready);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Downloads the card's on-demand model (domestic mirror), reports it to
  /// the backend so the card activates, and refreshes the active lists.
  Future<void> _downloadModel(String channelId) async {
    if (_downloading.containsKey(channelId)) return;
    setState(() => _downloading[channelId] = 0);
    try {
      final bytes = await models.downloadOnDeviceModel(
        channelId,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _downloading[channelId] = p.fraction);
        },
      );
      await _api.reportModelDownloaded(channelId, bytes);
      if (!mounted) return;
      setState(() {
        _downloading.remove(channelId);
        _modelReady.add(channelId);
      });
      await _load();
      if (mounted) OmiFeedback.confirm(context, context.l10n.providerModelDownloaded);
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading.remove(channelId));
      OmiFeedback.error(context, context.l10n.providerModelDownloadFailed);
    }
  }

  /// Deletes the card's model files and tells the backend (card deactivates).
  Future<void> _removeModel(String channelId) async {
    try {
      await models.deleteOnDeviceModel(channelId);
      await _api.reportModelRemoved(channelId);
      if (!mounted) return;
      setState(() => _modelReady.remove(channelId));
      await _load();
    } catch (_) {
      if (!mounted) return;
      OmiFeedback.error(context, context.l10n.providerModelDownloadFailed);
    }
  }

  /// Candidate models for a card row: discovered then static, newest first.
  /// The backend applies the same ordering, so the first entry is the default.
  List<String> _candidates(api.ProviderAccount account, String cap) {
    final channel = _channelOf(account.id);
    final discovered = account.discoveredModels[cap] ?? const <String>[];
    final staticList = channel?.staticModels[cap] ?? const <String>[];
    final merged = <String>[...discovered];
    for (final m in staticList) {
      if (!merged.contains(m)) merged.add(m);
    }
    final manual = account.selectedModels[cap];
    if (manual != null && manual.isNotEmpty && !merged.contains(manual)) {
      merged.insert(0, manual);
    }
    return merged;
  }

  String _effectiveModel(api.ProviderAccount account, String cap) {
    final selected = account.selectedModels[cap] ?? '';
    if (selected.isNotEmpty) return selected;
    final cands = _candidates(account, cap);
    return cands.isEmpty ? '' : cands.first;
  }

  void _setModel(String channelId, String cap, String model) {
    final draft = _draft;
    if (draft == null) return;
    final account = draft.account(channelId);
    if (account == null) return;
    final next = account.copyWith(
      selectedModels: {...account.selectedModels, cap: model},
    );
    setState(() => _draft = _withAccount(draft, next));
  }

  void _setRoute(String cap, String channelId) {
    final draft = _draft;
    if (draft == null) return;
    final routes = Map<String, api.RouteChain>.of(draft.routing);
    final existing = routes[cap] ?? const api.RouteChain();
    routes[cap] = api.RouteChain(
      primary: channelId,
      fallbacks: existing.fallbacks.where((f) => f != channelId).toList(),
    );
    setState(() => _draft = api.ProviderSettings(
          version: draft.version,
          accounts: draft.accounts,
          routing: routes,
        ));
  }

  static api.ProviderSettings _withAccount(api.ProviderSettings settings, api.ProviderAccount account) {
    final accounts = <api.ProviderAccount>[];
    var replaced = false;
    for (final a in settings.accounts) {
      if (a.id == account.id) {
        accounts.add(account);
        replaced = true;
      } else {
        accounts.add(a);
      }
    }
    if (!replaced) accounts.add(account);
    return api.ProviderSettings(version: settings.version, accounts: accounts, routing: settings.routing);
  }

  /// Ensure a card exists for a catalog channel the user has not added yet.
  api.ProviderAccount _ensureCard(String channelId) {
    final draft = _draft!;
    final existing = draft.account(channelId);
    if (existing != null) return existing;
    final channel = _channelOf(channelId);
    final card = api.ProviderAccount(
      id: channelId,
      defaultVoice: channel?.defaultVoice ?? '',
    );
    setState(() => _draft = _withAccount(draft, card));
    return card;
  }

  Future<void> _saveKey(String channelId) async {
    final controller = _keyControllers[channelId];
    final key = controller?.text.trim() ?? '';
    if (key.isEmpty) return;
    try {
      final activated = await _api.setKey(channelId, key);
      if (!mounted) return;
      controller?.clear();
      if (activated) {
        _ensureCard(channelId);
        await _load();
      }
      if (!mounted) return;
      OmiFeedback.confirm(context, context.l10n.providerKeySaved);
    } catch (_) {
      if (!mounted) return;
      OmiFeedback.error(context, context.l10n.providerSaveFailed);
    }
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null) return;
    try {
      final saved = await _api.saveSettings(draft);
      if (!mounted) return;
      setState(() => _draft = saved);
      OmiFeedback.confirm(context, context.l10n.providerSaved);
    } catch (_) {
      if (!mounted) return;
      OmiFeedback.error(context, context.l10n.providerSaveFailed);
    }
  }

  String _capabilityLabel(String cap) => switch (cap) {
        'asr' => context.l10n.providerCapabilityAsr,
        'tts' => context.l10n.providerCapabilityTts,
        'llm' => context.l10n.providerCapabilityLlm,
        'realtime' => context.l10n.providerCapabilityRealtime,
        'vision' => context.l10n.providerCapabilityVision,
        'video' => context.l10n.providerCapabilityVideo,
        'embed' => '嵌入',
        _ => cap,
      };

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return Scaffold(
      key: const ValueKey('settings_page_provider_cards'),
      appBar: AppBar(
        leading: const OmiBackButton(),
        title: Text(context.l10n.providerCards),
        actions: [
          if (draft != null)
            TextButton(
              key: const ValueKey('provider_cards_save'),
              onPressed: _save,
              child: Text(context.l10n.save),
            ),
        ],
      ),
      body: _loading
          ? const OmiLoadingState()
          : _error != null
              ? OmiErrorState(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(OmiSpacing.lg, OmiSpacing.lg, OmiSpacing.lg, OmiSpacing.xxl),
                  children: [
                    ..._cardSections(draft),
                    const SizedBox(height: OmiSpacing.xl),
                    _unifiedChannelSection(draft),
                  ],
                ),
    );
  }

  List<Widget> _cardSections(api.ProviderSettings? draft) {
    if (draft == null) return const [];
    final widgets = <Widget>[
      OmiSectionHeader(
        context.l10n.providerCards,
        subtitle: context.l10n.providerCardsSubtitle,
      ),
    ];
    for (final account in draft.accounts) {
      widgets.add(_cardWidget(account));
      widgets.add(const SizedBox(height: OmiSpacing.md));
    }
    final addable = _catalog.where((c) => c.id != 'custom' && draft.account(c.id) == null).toList();
    if (addable.isNotEmpty) {
      widgets.add(
        OmiButton(
          label: context.l10n.providerAddCard,
          variant: OmiButtonVariant.secondary,
          expand: true,
          onPressed: () => _showAddCardSheet(addable),
        ),
      );
    }
    return widgets;
  }

  void _showAddCardSheet(List<api.ProviderChannel> addable) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OmiColors.surface1,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in addable)
              ListTile(
                title: Text(c.label, style: OmiType.body),
                onTap: () {
                  setState(() => _draft = _withAccount(
                      _draft!,
                      api.ProviderAccount(
                        id: c.id,
                        defaultVoice: c.defaultVoice,
                      )));
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// One provider card: label, activation state, every service with a model
  /// dropdown, and the key field for channels that need one.
  Widget _cardWidget(api.ProviderAccount account) {
    final channel = _channelOf(account.id);
    final label = channel?.label ?? account.id;
    final needsKey = channel?.requiresKey ?? true;
    final needsModel = channel?.requiresModel ?? false;
    final activeIds = _active.values.expand((ids) => ids).toSet();
    var activated = !needsKey || activeIds.contains(account.id);
    if (needsModel && !_modelReady.contains(account.id)) activated = false;
    final expanded = _expanded.contains(account.id);
    final caps = (account.capabilities.isNotEmpty
            ? account.capabilities.toList()
            : channel?.capabilities ?? const <String>[])
        .where(_cardCapabilities.contains)
        .toList()
      ..sort((a, b) => _cardCapabilities.indexOf(a).compareTo(_cardCapabilities.indexOf(b)));

    return Container(
      key: ValueKey('provider_card_${account.id}'),
      decoration: BoxDecoration(
        color: OmiColors.surface1,
        borderRadius: OmiRadius.lgAll,
        border: Border.all(color: OmiColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(account.id);
              } else {
                _expanded.add(account.id);
              }
            }),
            title: Text(label, style: OmiType.body),
            subtitle: Text(
              activated ? context.l10n.providerKeySaved : context.l10n.providerKeyMissing,
              style: OmiType.footnote.copyWith(
                color: activated ? OmiColors.success : OmiColors.textTertiary,
              ),
            ),
            trailing: Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: OmiColors.textTertiary,
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, color: OmiColors.border),
            Padding(
              padding: const EdgeInsets.all(OmiSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (needsModel) _modelDownloadRow(account.id),
                  for (final cap in caps) _modelRow(account, cap),
                  if (needsKey && !activated) ...[
                    const SizedBox(height: OmiSpacing.sm),
                    TextField(
                      key: ValueKey('provider_key_field_${account.id}'),
                      controller: _keyControllers.putIfAbsent(account.id, () => TextEditingController()),
                      obscureText: true,
                      style: OmiType.subhead,
                      decoration: transcriptionInputDecoration(
                        hint: context.l10n.providerApiKeyHint,
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.check, size: 18),
                          onPressed: () => _saveKey(account.id),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _modelRow(api.ProviderAccount account, String cap) {
    final candidates = _candidates(account, cap);
    final effective = _effectiveModel(account, cap);
    return Padding(
      padding: const EdgeInsets.only(bottom: OmiSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_capabilityLabel(cap), style: OmiType.footnote.copyWith(color: OmiColors.textSecondary)),
          const SizedBox(height: OmiSpacing.xxs),
          if (candidates.isEmpty)
            Text(
              account.defaultVoice.isNotEmpty && cap == 'tts' ? account.defaultVoice : '—',
              style: OmiType.subhead.copyWith(color: OmiColors.textTertiary),
            )
          else
            TranscriptionDropdown<String>(
              key: ValueKey('provider_model_${account.id}_$cap'),
              value: candidates.contains(effective) ? effective : candidates.first,
              items: [
                for (final m in candidates)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v != null) _setModel(account.id, cap, v);
              },
            ),
        ],
      ),
    );
  }

  /// The on-demand model row of a `requiresModel` card: download with
  /// progress, or "downloaded" with remove.
  Widget _modelDownloadRow(String id) {
    final progress = _downloading[id];
    final sizeMb = ((models.kOnDeviceModelSizeBytes[id] ?? 0) / 1048576).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: OmiSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (progress != null) ...[
            Text(
              '${context.l10n.providerModelDownloading} ${(progress * 100).toStringAsFixed(0)}%',
              style: OmiType.footnote.copyWith(color: OmiColors.textSecondary),
            ),
            const SizedBox(height: OmiSpacing.xxs),
            LinearProgressIndicator(
              key: ValueKey('provider_model_progress_$id'),
              value: progress,
              minHeight: 4,
            ),
          ] else if (_modelReady.contains(id)) ...[
            Row(
              children: [
                Icon(Icons.check_circle, size: 16, color: OmiColors.success),
                const SizedBox(width: OmiSpacing.xs),
                Text(context.l10n.providerModelDownloaded, style: OmiType.footnote),
                const Spacer(),
                IconButton(
                  key: ValueKey('provider_model_remove_$id'),
                  icon: Icon(Icons.delete_outline, size: 18, color: OmiColors.textTertiary),
                  onPressed: () => _removeModel(id),
                ),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${context.l10n.providerModelNotDownloaded} (${sizeMb}MB)',
                    style: OmiType.footnote.copyWith(color: OmiColors.textTertiary),
                  ),
                ),
                OmiButton(
                  key: ValueKey('provider_model_download_$id'),
                  label: context.l10n.providerModelDownload,
                  variant: OmiButtonVariant.secondary,
                  onPressed: () => _downloadModel(id),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Unified channel: one dropdown per routed service listing only activated
  /// providers.
  Widget _unifiedChannelSection(api.ProviderSettings? draft) {
    if (draft == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmiSectionHeader(
          context.l10n.providerUnifiedChannel,
          subtitle: context.l10n.providerUnifiedChannelSubtitle,
        ),
        for (final cap in _routedCapabilities) _routeRow(draft, cap),
      ],
    );
  }

  Widget _routeRow(api.ProviderSettings draft, String cap) {
    final activeIds = _active[cap] ?? const <String>[];
    final current = draft.routing[cap]?.primary ?? '';
    final selected = activeIds.contains(current) ? current : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: OmiSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_capabilityLabel(cap), style: OmiType.footnote.copyWith(color: OmiColors.textSecondary)),
          const SizedBox(height: OmiSpacing.xxs),
          if (activeIds.isEmpty)
            Text(context.l10n.providerNoActiveProviders,
                style: OmiType.footnote.copyWith(color: OmiColors.textTertiary))
          else
            TranscriptionDropdown<String>(
              key: ValueKey('provider_route_$cap'),
              value: selected.isEmpty ? null : selected,
              hint: '—',
              items: [
                for (final id in activeIds)
                  DropdownMenuItem(
                    value: id,
                    child: Text(_channelOf(id)?.label ?? id, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v != null) _setRoute(cap, v);
              },
            ),
        ],
      ),
    );
  }
}
