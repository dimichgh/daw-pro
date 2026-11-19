/**
 * sing-expansion-tools.test.ts — p2-sing-x7 part A (W8-X7A): the singing expansion's MCP side (design
 * docs/design/2026-10-06-p2-sing-expansion.md §3.4, §4.7, §5.6, §6.9, §8.1, §9.2 S6).
 *
 * Same stub-bridge / InMemoryTransport pattern as sing-tools.test.ts: `DawBridge.prototype.send` is replaced, so no
 * app and no socket are needed. Pinned here:
 *   - one test per new tool: the name -> verb mapping, its `required` list and params, the arguments reaching the
 *     bridge unchanged, strictness (mutating tools refuse an unknown key before the bridge);
 *   - S6, npm side: EVERY tool's `required` list equals the one captured on the unchanged tree (285 tools, measured
 *     2026-10-07 00:16 from the built server), except the ONE deliberate change, clip_set_lyrics' `text` (now
 *     optional, because `wordless` replaces it), and no new param appears in any `required` list;
 *   - the new params of clip_set_lyrics, and the documented fields of mixer_apply_preset / macro_song_skeleton.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge, bridgeTimeoutMs } from "../src/bridge.js";

interface RecordedCall {
  command: string;
  params: Record<string, unknown>;
}

let calls: RecordedCall[];
let queuedResult: unknown;

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "sing-expansion-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { ok: true };
});

const CLIP = "7C70224C-A6A0-47BF-B905-55769739D1BA";
const NOTE = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427";

interface ToolRow {
  tool: string;
  verb: string;
  required: string[];
  params: string[];
  args: Record<string, unknown>;
  mutating: boolean;
}

/** The five new tools, in the wire's `allCommands` order. */
const NEW_TOOLS: ToolRow[] = [
  { tool: "clip_set_note_word", verb: "clip.setNoteWord", required: ["clipId", "noteId", "word"],
    params: ["clipId", "noteId", "word", "dryRun"],
    args: { clipId: CLIP, noteId: NOTE, word: "star", dryRun: true }, mutating: true },
  { tool: "clip_set_sing_style", verb: "clip.setSingStyle", required: ["clipId"],
    params: ["clipId", "vibrato", "air", "followVelocity", "notes", "clear"],
    args: { clipId: CLIP, vibrato: "gentle", air: 0.25, followVelocity: true,
            notes: [{ noteId: NOTE, vibrato: "wide", air: 0 }] },
    mutating: true },
  { tool: "clip_get_sing_style", verb: "clip.getSingStyle", required: ["clipId"], params: ["clipId"],
    args: { clipId: CLIP }, mutating: false },
  { tool: "sing_propose_harmony", verb: "sing.proposeHarmony", required: ["clipId", "interval", "direction"],
    params: ["clipId", "interval", "direction", "chordSource", "key", "mode", "voiceId"],
    args: { clipId: CLIP, interval: "third", direction: "above", chordSource: "none", key: 9, mode: "minor",
            voiceId: "builtin-1" },
    mutating: false },
  { tool: "sing_capabilities", verb: "sing.capabilities", required: [], params: [], args: {}, mutating: false },
];

async function listed(name: string) {
  const tool = (await client.listTools()).tools.find((t) => t.name === name);
  assert.ok(tool, `${name} must be listed`);
  return tool!;
}

function schemaOf(tool: { inputSchema: unknown }) {
  return tool.inputSchema as { required?: string[]; properties?: Record<string, any> };
}

for (const row of NEW_TOOLS) {
  test(`${row.tool}: required ${JSON.stringify(row.required)}, params exact, forwards to ${row.verb} unchanged`, async () => {
    const tool = await listed(row.tool);
    assert.match(tool.description ?? "", /DAW Pro can SING a melody/, `${row.tool} explains singing`);
    assert.ok((tool.title ?? "").length > 0);
    const schema = schemaOf(tool);
    assert.deepEqual([...(schema.required ?? [])].sort(), [...row.required].sort(), "required");
    assert.deepEqual(Object.keys(schema.properties ?? {}).sort(), [...row.params].sort(), "params");
    const result = (await client.callTool({ name: row.tool, arguments: row.args })) as any;
    assert.ok(!result.isError, JSON.stringify(result.content));
    assert.equal(calls.length, 1);
    assert.equal(calls[0]!.command, row.verb);
    assert.deepEqual(JSON.parse(JSON.stringify(calls[0]!.params)), row.args);
    assert.equal(bridgeTimeoutMs(row.verb, {}), 5000, "the default bridge tier: every one answers at once");
    calls = [];
    const typo = (await client.callTool({ name: row.tool, arguments: { ...row.args, extraKey: 1 } })) as any;
    if (row.mutating) {
      assert.ok(typo.isError, `${row.tool} is mutating: an unknown key is refused at the boundary`);
      assert.equal(calls.length, 0);
    } else {
      assert.ok(!typo.isError, `${row.tool} is read-only and registers directly`);
      assert.ok(!("extraKey" in calls[0]!.params), "the extra key never reaches the app");
    }
  });
}

test("clip_set_sing_style: a typo inside a notes[] entry is refused at the boundary (nested strict), the enums too", async () => {
  for (const args of [
    { clipId: CLIP, notes: [{ noteId: NOTE, vibe: "wide" }] },
    { clipId: CLIP, vibrato: "shaky" },
    { clipId: CLIP, air: 1.5 },
  ]) {
    calls = [];
    const result = (await client.callTool({ name: "clip_set_sing_style", arguments: args })) as any;
    assert.ok(result.isError, JSON.stringify(args));
    assert.equal(calls.length, 0);
  }
  const clear = (await client.callTool({ name: "clip_set_sing_style", arguments: { clipId: CLIP, clear: true } })) as any;
  assert.ok(!clear.isError);
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0]!.params)), { clipId: CLIP, clear: true });
});

test("clip_set_lyrics: language, wordless and wordlessPerNote reach clip.setLyrics; text is optional ONLY so wordless can replace it", async () => {
  const tool = await listed("clip_set_lyrics");
  const schema = schemaOf(tool);
  assert.deepEqual([...(schema.required ?? [])].sort(), ["clipId"]);
  assert.deepEqual(Object.keys(schema.properties ?? {}).sort(),
    ["clipId", "dryRun", "language", "text", "wordless", "wordlessPerNote"]);
  assert.deepEqual(schema.properties!.language.enum, ["en", "zh", "yue"], "Spanish is out of this build");
  assert.deepEqual(schema.properties!.wordless.enum, ["ooh", "aah", "mm"]);
  for (const args of [
    { clipId: CLIP, text: "一二三四", language: "zh" },
    { clipId: CLIP, wordless: "ooh" },
    { clipId: CLIP, wordless: "mm", wordlessPerNote: true, dryRun: true },
    { clipId: CLIP, text: "row row row" },
  ]) {
    calls = [];
    const result = (await client.callTool({ name: "clip_set_lyrics", arguments: args })) as any;
    assert.ok(!result.isError, JSON.stringify(result.content));
    assert.equal(calls[0]!.command, "clip.setLyrics");
    assert.deepEqual(JSON.parse(JSON.stringify(calls[0]!.params)), args);
  }
  calls = [];
  const spanish = (await client.callTool({ name: "clip_set_lyrics", arguments: { clipId: CLIP, text: "hola", language: "es" } })) as any;
  assert.ok(spanish.isError, "es is refused at the boundary");
  assert.equal(calls.length, 0);
  const description = tool.description ?? "";
  for (const needle of ["wordless", "language", "lyricsLanguageUnsupported", "lyricsScriptMismatch", "clip_set_note_word"]) {
    assert.ok(description.includes(needle), `clip_set_lyrics teaches ${needle}`);
  }
});

test("clip_get_lyrics says `language` is present ONLY when the clip has one", async () => {
  const tool = await listed("clip_get_lyrics");
  assert.match(tool.description ?? "", /`language` .* is present ONLY when/);
});

test("mixer_apply_preset documents removedSidechainKeys (always present) and the mid-take refusal, verbatim from the store", async () => {
  const description = (await listed("mixer_apply_preset")).description ?? "";
  assert.ok(description.includes("removedSidechainKeys"));
  assert.ok(description.includes("ALWAYS present"));
  assert.ok(description.includes("[{effectId, kind, sourceTrackId, sourceTrackName"));
  assert.ok(description.includes("cannot apply a preset that removes a sidechain-keyed effect while recording — stop first"));
});

test("macro_song_skeleton names its two tempo refusals, verbatim from the store", async () => {
  const description = (await listed("macro_song_skeleton")).description ?? "";
  assert.ok(description.includes("cannot change tempo while recording — stop first"));
  assert.ok(description.includes(
    "this project has a multi-segment tempo map — use tempo.setMap to edit it (transport.setTempo sets a single " +
      "project-wide tempo and would flatten the map)"));
});

test("S6 (npm): every tool's `required` list equals the pin-before, except clip_set_lyrics' text; the five new tools are the only new names", async () => {
  const tools = (await client.listTools()).tools;
  const now: Record<string, string[]> = {};
  for (const t of tools) now[t.name] = [...(schemaOf(t).required ?? [])].sort();
  const before = Object.keys(REQUIRED_BEFORE);
  assert.equal(before.length, 285, "the pin holds the 285 tools of the unchanged tree");
  // m27-f (W8-M27F): tools that landed AFTER this pin was captured are not this
  // item's new names; list them here by name so a surprise tool still fails.
  // m39-w4-10 (W9-PATM): pattern_list and clip_add_drum_pattern landed later too.
  const LANDED_LATER = new Set(["fx_get_params", "pattern_list", "clip_add_drum_pattern"]);
  const added = Object.keys(now).filter((n) => !(n in REQUIRED_BEFORE) && !LANDED_LATER.has(n)).sort();
  assert.deepEqual(added, NEW_TOOLS.map((r) => r.tool).sort());
  const removed = before.filter((n) => !(n in now));
  assert.deepEqual(removed, [], "no tool disappeared");
  const changed = before.filter((n) => JSON.stringify(now[n]) !== JSON.stringify(REQUIRED_BEFORE[n]));
  // vf-18 leg 2 (W9-SLWR): clip_set_note_pitches' `notes` became optional (exactly one of notes /
  // moveByCents; the app owns the refusal), so it LOST `notes` from its required list too.
  assert.deepEqual(changed, ["clip_set_lyrics", "clip_set_note_pitches"], "the two deliberate required-list changes");
  assert.deepEqual(REQUIRED_BEFORE["clip_set_note_pitches"], ["clipId", "notes"]);
  assert.deepEqual(now["clip_set_note_pitches"], ["clipId"], "it only LOST notes (to moveByCents); it gained nothing");
  assert.deepEqual(REQUIRED_BEFORE["clip_set_lyrics"], ["clipId", "text"]);
  assert.deepEqual(now["clip_set_lyrics"], ["clipId"], "it only LOST text (to wordless); it gained nothing");
});

const REQUIRED_BEFORE: Record<string, string[]> = {
  "ai_copilot_chats": [],
  "ai_copilot_delete_chat": ["chatId"],
  "ai_copilot_get_model": [],
  "ai_copilot_rename_chat": ["chatId", "title"],
  "ai_copilot_reset": [],
  "ai_copilot_resume_chat": ["chatId"],
  "ai_copilot_send": ["message"],
  "ai_copilot_set_model": ["model"],
  "ai_copilot_state": [],
  "ai_fix_clip_region": ["clipId", "endBeat", "startBeat", "trackId"],
  "ai_import_clip_fix": ["jobId"],
  "ai_install_speech_model": ["variant"],
  "ai_model_residency": [],
  "ai_model_unload": [],
  "ai_provider_status": [],
  "ai_repaint_audio": ["sourcePath", "start"],
  "ai_sidecar_start": [],
  "ai_sidecar_status": [],
  "ai_sidecar_stop": [],
  "ai_speech_model_install_status": [],
  "ai_write_lyrics": ["prompt"],
  "app_connection_info": [],
  "app_feedback_bundle": [],
  "arrange_delete_bars": ["count", "fromBar"],
  "arrange_insert_bars": ["atBar", "count"],
  "au_describe_params": ["trackId"],
  "au_list_presets": ["trackId"],
  "au_load_preset": ["trackId"],
  "au_set_param": ["address", "trackId", "value"],
  "audio_profile_file": ["path", "windowSeconds"],
  "automation_add_lane": ["target", "trackId"],
  "automation_remove_lane": ["laneId", "trackId"],
  "automation_set_lane_enabled": ["enabled", "laneId", "trackId"],
  "automation_set_points": ["laneId", "points", "trackId"],
  "chord_voice": [],
  "clip_add_audio": ["path", "trackId"],
  "clip_add_midi": ["trackId"],
  "clip_analyze_audio": ["clipId"],
  "clip_apply_breath_contour": ["clipId"],
  "clip_apply_effort_shape": ["clipId"],
  "clip_audition_note": ["clipId", "segmentIds"],
  "clip_auto_correct_pitch": ["clipId"],
  "clip_clear_pitch_edits": ["clipId"],
  "clip_crossfade": ["clipId", "lengthBeats", "otherClipId", "trackId"],
  "clip_delete_time_range": ["clipId", "lengthBeats", "startBeat"],
  "clip_detect_pitch": ["clipId"],
  "clip_detect_transients": ["clipId"],
  "clip_duplicate": ["clipId"],
  "clip_find_unpitched_sounds": ["clipId"],
  "clip_fit_to_content": ["clipId", "trackId"],
  "clip_get_lyrics": ["clipId"],
  "clip_get_notes": ["clipId"],
  "clip_get_pitch_edits": ["clipId"],
  "clip_get_played_pitch": ["clipId"],
  "clip_humanize": ["clipId"],
  "clip_import_midi": ["clipId", "path"],
  "clip_insert_time_range": ["atBeat", "clipId", "lengthBeats"],
  "clip_move": ["clipId", "toStartBeat", "trackId"],
  "clip_move_many": ["byBeats", "ids"],
  "clip_move_many_by_tracks": ["byTracks", "ids"],
  "clip_move_many_to_track": ["ids", "toTrackId"],
  "clip_patch_notes": ["clipId", "update"],
  "clip_quantize": ["clipId", "gridBeats"],
  "clip_quantize_audio": ["clipId", "trackId"],
  "clip_remove": ["clipId"],
  "clip_remove_controller_lane": ["clipId", "type"],
  "clip_remove_many": ["ids"],
  "clip_repeat_notes": ["clipId", "count", "periodBeats"],
  "clip_set_consonant_protection": ["clipId", "enabled"],
  "clip_set_controller_lane": ["clipId", "points", "type"],
  "clip_set_fades": ["clipId", "fadeInBeats", "fadeOutBeats", "trackId"],
  "clip_set_formant_correction": ["clipId"],
  "clip_set_gain": ["clipId", "gainDb", "trackId"],
  "clip_set_gain_envelope": ["clipId", "trackId"],
  "clip_set_lyrics": ["clipId", "text"],
  "clip_set_note_cleared": ["cleared", "clipId", "segmentIds"],
  "clip_set_note_formant": ["clipId", "formantSemitones", "segmentIds"],
  "clip_set_note_gain": ["clipId", "gainDb", "segmentIds"],
  "clip_set_note_glide_follow": ["amount", "clipId", "noteId"],
  "clip_set_note_pitch": ["cents", "clipId", "segmentId"],
  "clip_set_note_pitches": ["clipId", "notes"],
  "clip_set_note_shape": ["clipId", "noteId"],
  "clip_set_note_shapes": ["clipId", "notes"],
  "clip_set_note_transition": ["clipId", "noteId"],
  "clip_set_note_vibrato": ["clipId", "segmentId"],
  "clip_set_note_vibratos": ["clipId", "notes"],
  "clip_set_notes": ["clipId", "notes"],
  "clip_set_pitch_transition_smoothness": ["clipId"],
  "clip_set_stretch": ["clipId", "trackId"],
  "clip_slice_to_sampler": ["clipId"],
  "clip_split": ["atBeat", "clipId", "trackId"],
  "clip_split_note": ["atSourceSeconds", "clipId", "segmentId"],
  "clip_stretch_to_length": ["clipId", "lengthBeats", "trackId"],
  "clip_transcribe": ["clipId"],
  "clip_trim": ["clipId", "newLengthBeats", "newStartBeat", "trackId"],
  "clip_upgrade_natural_tuning": ["clipId"],
  "edit_history": [],
  "edit_paste_clips": [],
  "edit_redo": [],
  "edit_undo": [],
  "engine_au_prepare_stats": [],
  "engine_performance_stats": [],
  "engine_watchdog_status": [],
  "extract_stems": ["sourceAudioPath", "trackNames"],
  "frequency_reference": [],
  "fx_add": ["trackId"],
  "fx_describe": [],
  "fx_list_audio_units": [],
  "fx_remove": ["effectId", "trackId"],
  "fx_reorder": ["effectId", "index", "trackId"],
  "fx_set_bypass": ["bypassed", "effectId", "trackId"],
  "fx_set_param": ["effectId", "name", "trackId", "value"],
  "fx_set_sidechain": ["effectId", "trackId"],
  "fx_spectrum": ["effectId", "trackId"],
  "generate_image": ["prompt"],
  "generate_lyrics": ["theme"],
  "generate_song": ["prompt"],
  "generate_song_suno": ["prompt"],
  "generation_status": ["jobId"],
  "groove_extract": ["clipId", "name"],
  "groove_list": [],
  "groove_remove": ["grooveId"],
  "import_generated_stems": ["jobId"],
  "import_generation": ["jobId"],
  "input_list_devices": [],
  "input_set_device": [],
  "instrument_cancel_sound_bank_download": [],
  "instrument_describe_drum_kit": ["trackId"],
  "instrument_describe_sampler": ["trackId"],
  "instrument_describe_synth": ["trackId"],
  "instrument_download_sound_bank": ["id"],
  "instrument_import_sample_library": ["path", "trackId"],
  "instrument_import_sound_bank": ["path"],
  "instrument_list_audio_units": [],
  "instrument_list_downloadable_sound_banks": [],
  "instrument_list_drum_presets": [],
  "instrument_list_sound_bank_programs": ["source"],
  "instrument_list_sound_banks": [],
  "instrument_load_drum_preset": ["name", "trackId"],
  "instrument_probe_liveness": ["trackId"],
  "instrument_set_drum_param": ["name", "trackId", "value"],
  "instrument_set_sampler_param": ["param", "trackId", "value"],
  "instrument_set_sampler_zones": ["trackId", "zones"],
  "instrument_set_spread_direction": ["direction", "spreadZoneId", "trackId"],
  "instrument_sound_bank_download_status": [],
  "instrument_spread_slice": ["trackId", "zoneId"],
  "lego_generate": ["globalCaption", "sourceAudioPath", "tracks"],
  "looper_arm_layer": ["trackId"],
  "looper_begin": [],
  "looper_end": [],
  "looper_finish_layer": [],
  "looper_set_layer_muted": ["layerId", "muted"],
  "looper_status": [],
  "looper_undo_layer": [],
  "macro_song_skeleton": ["genre"],
  "marker_add": ["beat"],
  "marker_list": [],
  "marker_move": ["beat", "markerId"],
  "marker_remove": ["markerId"],
  "marker_rename": ["markerId", "name"],
  "midi_get_control_map": [],
  "midi_learn_control": [],
  "midi_list_inputs": [],
  "midi_set_control_map": ["bindings"],
  "mixer_apply_preset": ["preset", "trackId"],
  "mixer_live_loudness": [],
  "mixer_master_analysis": [],
  "mixer_set_master_volume": ["volume"],
  "mod_add_route": ["depth", "sourceId", "target", "trackId"],
  "mod_add_source": ["kind", "trackId"],
  "mod_describe": [],
  "mod_describe_kinds": [],
  "mod_remove_route": ["routeId", "trackId"],
  "mod_remove_source": ["sourceId", "trackId"],
  "mod_set_macro": ["sourceId", "trackId", "value"],
  "mod_set_route_depth": ["routeId", "trackId"],
  "mod_set_source": ["sourceId", "trackId"],
  "note_audition": ["pitches", "trackId"],
  "note_play": ["pitches", "trackId"],
  "output_list_devices": [],
  "output_set_device": [],
  "pad_play_effort": ["gesture", "trackId"],
  "pad_preview_effort": ["gesture", "trackId"],
  "play_sustain": ["down", "trackId"],
  "playbox_generate": [],
  "plugin_close_ui": ["trackId"],
  "plugin_list_open_uis": [],
  "plugin_open_ui": ["trackId"],
  "project_embedded_voices": [],
  "project_export_midi": [],
  "project_import_midi": ["path"],
  "project_new": [],
  "project_open": ["path"],
  "project_overview": [],
  "project_recover": ["accept"],
  "project_recovery_bundles": [],
  "project_recovery_status": [],
  "project_save": [],
  "project_snapshot": [],
  "project_transpose": ["semitones"],
  "reference_analyze": [],
  "reference_compare": [],
  "reference_import": ["path"],
  "reference_remove": [],
  "reference_set_monitor": ["on"],
  "reference_set_offset": ["seconds"],
  "reference_set_trim": ["db"],
  "reference_status": [],
  "render_bounce": [],
  "render_measure_loudness": [],
  "render_mixdown": [],
  "render_stems": [],
  "sing_add_voice": [],
  "sing_cancel_install": [],
  "sing_cancel_job": ["jobId"],
  "sing_install_engine": [],
  "sing_job_status": [],
  "sing_list_voices": [],
  "sing_open_voice_recorder": [],
  "sing_propose_key": ["clipId"],
  "sing_remove_voice": ["voiceId"],
  "sing_render": ["clipId"],
  "sing_sidecar_start": [],
  "sing_sidecar_status": [],
  "sing_sidecar_stop": [],
  "sing_uninstall_engine": [],
  "take_auto_align": ["groupId", "laneId", "trackId"],
  "take_flatten": ["groupId", "trackId"],
  "take_group": ["clipIds", "trackId"],
  "take_move": ["groupId", "toStartBeat", "trackId"],
  "take_remove_lane": ["groupId", "laneId", "trackId"],
  "take_select": ["groupId", "laneId", "trackId"],
  "take_set_comp": ["groupId", "segments", "trackId"],
  "take_set_crossfade": ["groupId", "seconds", "trackId"],
  "template_apply": ["template"],
  "template_describe": ["template"],
  "template_export": ["id", "path"],
  "template_import": ["path"],
  "template_list": [],
  "template_remove": ["id"],
  "template_save": ["name", "trackIds"],
  "tempo_map": [],
  "tempo_set_map": ["segments"],
  "track_add": ["name"],
  "track_add_send": ["busId", "trackId"],
  "track_bounce_in_place": ["trackId"],
  "track_export_midi": ["trackId"],
  "track_remove": ["trackId"],
  "track_remove_send": ["sendId", "trackId"],
  "track_rename": ["name", "trackId"],
  "track_reorder": ["index", "trackId"],
  "track_set_arm": ["armed", "trackId"],
  "track_set_instrument": ["trackId"],
  "track_set_mute": ["muted", "trackId"],
  "track_set_output": ["trackId"],
  "track_set_pan": ["pan", "trackId"],
  "track_set_send": ["level", "sendId", "trackId"],
  "track_set_solo": ["soloed", "trackId"],
  "track_set_volume": ["trackId", "volume"],
  "transport_finish_layer": [],
  "transport_panic": [],
  "transport_play": [],
  "transport_record": [],
  "transport_record_layer": [],
  "transport_seek": [],
  "transport_set_loop": ["enabled"],
  "transport_set_metronome": ["enabled"],
  "transport_set_punch": ["enabled"],
  "transport_set_stop_at_content_end": ["enabled"],
  "transport_set_tempo": ["bpm"],
  "transport_stop": [],
  "vc_convert_clips": ["clipIds", "voiceId"],
  "vc_convert_vocals": ["voiceId"],
  "vc_import_voice_model": ["modelPath"],
  "vc_install_embedded_voice": ["voiceId"],
  "vc_list_voices": [],
  "vc_sidecar_start": [],
  "vc_sidecar_status": [],
  "vc_sidecar_stop": [],
  "vc_train_voice": ["datasetDir", "name"],
  "view_capture": [],
  "view_open_editor": ["trackId"],
  "view_open_pitch_editor": ["clipId"],
  "view_panel_layout": [],
  "view_select_clip": ["clipId"],
};
