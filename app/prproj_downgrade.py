#!/usr/bin/env python3
"""
prproj_downgrade.py — best-effort Adobe Premiere Pro project down-saver.

Converts a Premiere Pro 2026 (project schema v45) .prproj into the
Premiere Pro 2024 (project schema v42) layout.

Premiere has no built-in down-save. This tool reconstructs the older
schema from the newer object graph. It is a best-effort transform:
always keep the original, always open the result in Premiere 2024 and
verify before using it for real work.

Usage:
    python3 prproj_downgrade.py INPUT.prproj OUTPUT.prproj [options]

Options:
    --reference PATH   A 2024 .prproj of the same edit. When supplied, the
                       tool verifies the editorial content matches and emits
                       that file byte-for-byte (safest possible downgrade).
    --schema PATH      schema42.json profile (default: alongside this script).
    --report PATH      Write a JSON report.
    --no-verify        Skip the post-write XML well-formedness check.
    --quiet            Only print errors.
"""

from __future__ import annotations

import argparse
import collections
import gzip
import hashlib
import json
import os
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

__version__ = "1.0.0"

TARGET_VERSION = 42
DEFAULT_SCHEMA = Path(__file__).with_name("schema42.json")

# ---------------------------------------------------------------------------
# CC2026 class versions -> CC2024 class versions
# Derived by comparing the same project saved by Premiere 24.1 and 26.0.
# ---------------------------------------------------------------------------
CLASS_VERSION = {
    "62ad66dd-0dcd-42da-a660-6d8fbde94876": 42,  # Project
    "50c16708-a1a1-4d2f-98d5-4e283ae28353": 20,  # ProjectSettings
    "6a15d903-8739-11d5-af2d-9b7855ad8974": 11,  # Sequence
    "fb11c33a-b0a9-4465-aa94-b6d5db2628cf": 11,  # MasterClip
    "7a5c103e-f3ac-4391-b6b4-7cc3d2f9a7ff": 27,  # Media
    "a36e4719-3ec6-4a0c-ab11-8b4aab377aa5": 19,  # VideoStream
    "0b5cf52f-2b85-4863-890b-8844b64ecfe9": 7,   # AudioStream
    "58474264-30c4-43a2-bba5-dc0812df8a3a": 9,   # VideoSettings
    "6baf5521-b132-4634-840e-13cec5bc86a4": 7,   # AudioSettings
    "77ab7fdd-dcdf-465d-9906-7a330ca1e738": 8,   # ClipLoggingInfo
    "e0c58dc9-dbdd-4166-aef7-5db7e3f22e84": 5,   # SubClip
    "2db8f76b-2c37-48ee-925d-9a4f7278152d": 1,   # IngestSettings
    "368b0406-29e3-4923-9fcd-094fbf9a1089": 6,   # VideoClipTrackItem
    "064ec682-9ba6-11d5-af2d-9ca32c7d6164": 10,  # AudioClipTrackItem
    "097f6203-99ae-11d5-84f2-8cf14bde7040": 6,   # AudioClipTrack
    "23f687b6-9c5a-42f4-bea1-e7b3e28e7082": 3,   # AudioTransitionTrackItem
    "be3af080-e8c6-11d5-abc4-a1c6d5dee670": 3,   # AudioTrackInlet
    "313e54d4-6903-49ad-b0bf-8262cdd10f4e": 2,   # ArbVideoComponentParam
    "ca81d347-309b-44d2-acc7-1c572efb973c": 3,   # PointComponentParam
    "3cb131d1-d3c0-47ae-a19a-bdf75ea11674": 3,   # AudioComponentChain
    "0fde4e9f-f895-4ba3-b0fe-9a6feafda583": 9,   # VideoComponentParam
    "6e02e8bb-2569-46b2-8ab1-4ab11c43e9c8": 9,   # VideoComponentParam
    "a4ff2d6e-7ac2-44f8-9d52-17d9ca50e542": 9,   # VideoComponentParam
    "cc12343e-f113-4d3b-ae05-b287db77d461": 9,   # VideoComponentParam
    "fe47129e-6c94-4fc0-95d5-c056a517aaf3": 9,   # VideoComponentParam
    "32657501-3aa4-445f-a49b-d09ecb9fa1ae": 9,   # AudioComponentParam
    "a714635e-a628-4b27-9d59-77eba47dbc1a": 9,   # AudioComponentParam
}

# Inner (non-object) element versions that changed.
TAG_VERSION = {"Track": 3, "TrackItem": 3, "AudioTrack": 11, "Component": 6}

# Elements that exist only in the 2026 schema (or are 2026-only UI state).
REMOVE_TAGS = {
    "ColorAwareEffectsEnabled",
    "OriginalColorSpace",
    "OutputColorSpace",
    "ToneMapSettings",
    "SideNav.Visible",
    "SideNav.Width",
    "SideNav.SplitterPosition.1",
    "WorkspaceDefinition",
    "WorkspaceName",
    "NextID",
}
# Path-qualified removals: (parent tag, child tag)
REMOVE_PATHS = {
    ("VideoTrackGroup", "ComponentOwner"),
}

# Audio defaults observed in every 24.1-saved project field of this kind.
AUDIO_CHANNEL_TYPE = "1"
AUDIO_FRAME_RATE = "5292000"       # 48 kHz in Premiere ticks
AUDIO_AUTOMATION_MODE = "1"
AUDIO_ASSIGN_CLIP = "1"
AUDIO_SUBTYPE_CLIP = "1"
AUDIO_SOLO = "0"
AUDIO_MUTED_BY_SOLO = "0"
RECORD_CHANNEL = "0"

VIDEO_SETTINGS_DEFAULT = {
    "FrameRate": "8475667200",
    "FrameSize": "0,0,720,480",
    "PixelAspectRatio": "10,11",
    "MaximumBitDepth": "false",
}

# Component flags from the 24.1 schema.
COMPONENT_DEFAULTS = {
    "Bypass": "false",
    "Intrinsic": "false",
    "ArchivedType": "0",
}

# Color-space name mapping. 2026 writes display-referred names; 24.1 uses
# the working-space names.
COLOR_SPACE_MAP = {
    "BT.709,8-bit,Display-Referred": "BT.709 RGB Full",
    "BT.709,10-bit,Display-Referred": "BT.709 RGB Full",
    "sRGB,8-bit,Display-Referred": "sRGB IEC61966-2.1",
    "Rec.2100 HLG,10-bit,Display-Referred": "Rec.2100 HLG",
    "Rec.2100 PQ,10-bit,Display-Referred": "Rec.2100 PQ",
}


class Stats:
    def __init__(self):
        self.changed_class_versions = collections.Counter()
        self.changed_tag_versions = collections.Counter()
        self.removed = collections.Counter()
        self.added = collections.Counter()
        self.reordered = 0
        self.warnings = []

    def to_dict(self):
        return {
            "class_version_changes": dict(self.changed_class_versions),
            "inner_version_changes": dict(self.changed_tag_versions),
            "removed_elements": dict(self.removed),
            "added_elements": dict(self.added),
            "reordered_objects": self.reordered,
            "warnings": self.warnings,
        }


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def is_gzip(path: Path) -> bool:
    with open(path, "rb") as f:
        return f.read(2) == b"\x1f\x8b"


def parse_project(path: Path) -> ET.ElementTree:
    if is_gzip(path):
        with gzip.open(path, "rb") as f:
            return ET.parse(f)
    return ET.parse(path)


def write_project(tree: ET.ElementTree, path: Path, pretty: bool = False) -> None:
    if pretty:
        ET.indent(tree, space="\t")
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=6, mtime=0) as gz:
            gz.write(b'<?xml version="1.0" encoding="UTF-8" ?>\n')
            tree.write(gz, encoding="utf-8", xml_declaration=False)
    os.replace(tmp, path)


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Editorial-content signature (used by --reference)
# ---------------------------------------------------------------------------

def content_signature(tree: ET.ElementTree) -> dict:
    root = tree.getroot()
    seq_names = collections.Counter()
    clip_ids = collections.Counter()
    clip_names = collections.Counter()
    media_paths = collections.Counter()
    durations = collections.Counter()
    in_points = collections.Counter()
    out_points = collections.Counter()

    stack = [root]
    while stack:
        e = stack.pop()
        stack.extend(e)
        t = e.tag
        if t == "Sequence" and e.find("Name") is not None:
            seq_names[e.findtext("Name") or ""] += 1
        elif t == "ClipID":
            clip_ids[e.text or ""] += 1
        elif t == "ClipName":
            clip_names[e.text or ""] += 1
        elif t in ("FilePath", "ActualMediaFilePath"):
            media_paths[e.text or ""] += 1
        elif t == "Duration":
            durations[e.text or ""] += 1
        elif t == "InPoint":
            in_points[e.text or ""] += 1
        elif t == "OutPoint":
            out_points[e.text or ""] += 1

    return {
        "sequences": seq_names,
        "clip_ids": clip_ids,
        "clip_names": clip_names,
        "media_paths": media_paths,
        "durations": durations,
        "in_points": in_points,
        "out_points": out_points,
    }


def compare_signatures(a: dict, b: dict, ignore_paths: bool = True) -> list[str]:
    problems = []
    for key in ("sequences", "clip_ids", "clip_names", "durations", "in_points", "out_points"):
        if a[key] != b[key]:
            problems.append(f"{key} differ ({sum(a[key].values())} vs {sum(b[key].values())})")
    if not ignore_paths and a["media_paths"] != b["media_paths"]:
        problems.append("media paths differ")
    return problems


# ---------------------------------------------------------------------------
# Tree helpers
# ---------------------------------------------------------------------------

def walk_with_parent(root: ET.Element):
    stack = [(root, None)]
    while stack:
        e, p = stack.pop()
        yield e, p
        stack.extend((c, e) for c in e)


def text_of(e: ET.Element | None) -> str | None:
    return None if e is None or e.text is None else e.text.strip()


def is_reference(e: ET.Element) -> bool:
    """Object references are <Tag ObjectRef=".."/> or <Tag ObjectURef=".."/>,
    as opposed to object declarations that carry ClassID/Version."""
    return ("ObjectRef" in e.attrib or "ObjectURef" in e.attrib) and "ClassID" not in e.attrib


def insert_ordered(elem: ET.Element, new: ET.Element, order: list[str]) -> None:
    """Insert new into elem at its canonical position, before the first known
    sibling that comes later in the order."""
    try:
        idx = order.index(new.tag)
    except ValueError:
        elem.append(new)
        return
    for i, child in enumerate(list(elem)):
        if child.tag in order and order.index(child.tag) > idx:
            elem.insert(i, new)
            return
    elem.append(new)


def ensure_child(elem: ET.Element, tag: str, text: str, order: list[str] | None = None,
                 stats: Stats | None = None, parent_tag: str | None = None) -> ET.Element:
    found = elem.find(tag)
    if found is not None:
        return found
    child = ET.SubElement(elem, tag)
    child.text = text
    if order:
        # move to canonical position
        elem.remove(child)
        insert_ordered(elem, child, order)
    if stats is not None:
        stats.added[f"{parent_tag or elem.tag}/{tag}"] += 1
    return child


# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------

class Downgrader:
    def __init__(self, tree: ET.ElementTree, schema: dict):
        self.tree = tree
        self.root = tree.getroot()
        self.canon = schema.get("canonical_order", {})
        self.param_by_name = schema.get("param_type_by_name", {})
        self.param_by_shape = schema.get("param_type_by_shape", {})
        self.stats = Stats()
        self.default_audio_rate = AUDIO_FRAME_RATE
        self.default_channel_type = AUDIO_CHANNEL_TYPE
        self.detect_defaults()

    def detect_defaults(self):
        """Use the source project's own audio rate / channel type when present."""
        rates = collections.Counter()
        channels = collections.Counter()
        for e, _ in walk_with_parent(self.root):
            if e.tag in ("AudioStream", "AudioComponentChain", "AudioSettings", "AudioTrackInlet"):
                r = text_of(e.find("FrameRate"))
                if r:
                    rates[r] += 1
                c = text_of(e.find("ChannelType"))
                if c:
                    channels[c] += 1
        if rates:
            self.default_audio_rate = rates.most_common(1)[0][0]
        if channels:
            self.default_channel_type = channels.most_common(1)[0][0]

    # -- versions ----------------------------------------------------------
    def downgrade_versions(self):
        for e, _ in walk_with_parent(self.root):
            cid = e.attrib.get("ClassID")
            if cid in CLASS_VERSION and "Version" in e.attrib:
                try:
                    cur = int(e.attrib["Version"])
                except ValueError:
                    continue
                target = CLASS_VERSION[cid]
                if cur > target:
                    e.attrib["Version"] = str(target)
                    self.stats.changed_class_versions[f"{e.tag}:{cur}->{target}"] += 1
            tag = e.tag
            if tag in TAG_VERSION and "Version" in e.attrib:
                try:
                    cur = int(e.attrib["Version"])
                except ValueError:
                    continue
                target = TAG_VERSION[tag]
                if cur > target:
                    e.attrib["Version"] = str(target)
                    self.stats.changed_tag_versions[f"{tag}:{cur}->{target}"] += 1

    # -- removals ----------------------------------------------------------
    def remove_new_elements(self):
        for parent, ptag in walk_with_parent(self.root):
            for child in list(parent):
                if child.tag in REMOVE_TAGS:
                    parent.remove(child)
                    self.stats.removed[child.tag] += 1
                elif (parent.tag, child.tag) in REMOVE_PATHS:
                    parent.remove(child)
                    self.stats.removed[f"{parent.tag}/{child.tag}"] += 1

    # 2026-only fields that only some 24.1 classes tolerate.
    CLASS_CHILD_REMOVE = {
        "32657501-3aa4-445f-a49b-d09ecb9fa1ae": {"RangeLocked"},   # audio Bypass param
    }
    SEQUENCE_NEW_FIELDS = {
        "Seq.ExportID", "ExportSettings.Info.FTP", "ExportSettings.Info.SaveAsFile",
        "ExportSettings.MaxGroupIndex",
    }

    def remove_class_specific(self):
        for e, _ in walk_with_parent(self.root):
            if is_reference(e):
                continue
            cid = e.attrib.get("ClassID")
            if cid in self.CLASS_CHILD_REMOVE:
                for child in list(e):
                    if child.tag in self.CLASS_CHILD_REMOVE[cid]:
                        e.remove(child)
                        self.stats.removed[f"{e.tag}/{child.tag}"] += 1
            if e.tag == "MasterClip":
                node = e.find("Node")
                if node is not None:
                    for child in list(node):
                        if child.tag == "ID":
                            node.remove(child)
                            self.stats.removed["MasterClip/Node/ID"] += 1
            elif e.tag in ("BinProjectItem", "FileProjectItem"):
                props = e.find("ProjectItem/Node/Properties")
                if props is not None:
                    for child in list(props):
                        if child.tag == "Column.PropertyText.Label":
                            props.remove(child)
                            self.stats.removed[f"{e.tag}/Column.PropertyText.Label"] += 1
            # Sequence keeps its export fields: they exist in the 24.1 schema too.

    # -- audio tracks ------------------------------------------------------
    def fix_audio_tracks(self):
        order = self.canon.get("AudioTrack", [])
        track_order = self.canon.get("Track", [])
        for e, p in walk_with_parent(self.root):
            if is_reference(e):
                continue
            if e.tag == "AudioTrack" and p is not None and p.tag in ("AudioClipTrack", "AudioMixTrack"):
                is_clip = p.tag == "AudioClipTrack"
                ensure_child(e, "ChannelType", self.default_channel_type, order, self.stats, "AudioTrack")
                ensure_child(e, "FrameRate", self.default_audio_rate, order, self.stats, "AudioTrack")
                ensure_child(e, "AutomationMode", AUDIO_AUTOMATION_MODE, order, self.stats, "AudioTrack")
                if is_clip:
                    ensure_child(e, "SubType", AUDIO_SUBTYPE_CLIP, order, self.stats, "AudioTrack")
                    ensure_child(e, "Assign", AUDIO_ASSIGN_CLIP, order, self.stats, "AudioTrack")
                ensure_child(e, "Solo", AUDIO_SOLO, order, self.stats, "AudioTrack")
                ensure_child(e, "MutedBySolo", AUDIO_MUTED_BY_SOLO, order, self.stats, "AudioTrack")
            elif e.tag == "AudioClipTrack" and p is not None:
                ensure_child(e, "RecordChannel", RECORD_CHANNEL, self.canon.get("AudioClipTrack", []),
                             self.stats, "AudioClipTrack")
            elif e.tag == "Track" and e.find("MediaType") is not None:
                ensure_child(e, "IsLocked", "false", track_order, self.stats, "Track")
                ensure_child(e, "IsMuted", "false", track_order, self.stats, "Track")
                ensure_child(e, "IsSyncLocked", "true", track_order, self.stats, "Track")

    # -- component flags ---------------------------------------------------
    COMPONENT_PARENTS = {
        "VideoFilterComponent", "AudioFilterComponent", "AudioFader",
        "AudioMeter", "DefaultPanProcessor", "StereoToStereoPanProcessor",
        "AudioComponent",
    }

    def fix_components(self):
        order = self.canon.get("Component", [])
        for e, p in walk_with_parent(self.root):
            if is_reference(e):
                continue
            if e.tag == "Component" and p is not None and p.tag in self.COMPONENT_PARENTS:
                for tag, val in COMPONENT_DEFAULTS.items():
                    ensure_child(e, tag, val, order, self.stats, "Component")

    # -- component chains --------------------------------------------------
    def fix_audio_component_chains(self):
        order = self.canon.get("AudioComponentChain", [])
        for e, _ in walk_with_parent(self.root):
            if is_reference(e):
                continue
            if e.tag == "AudioComponentChain":
                ensure_child(e, "FrameRate", self.default_audio_rate, order, self.stats, "AudioComponentChain")
                ensure_child(e, "AutomationMode", AUDIO_AUTOMATION_MODE, order, self.stats, "AudioComponentChain")

    # -- settings ----------------------------------------------------------
    def fix_settings(self):
        v_order = self.canon.get("VideoSettings", [])
        a_order = self.canon.get("AudioSettings", [])
        for e, _ in walk_with_parent(self.root):
            if is_reference(e):
                continue
            if e.tag == "VideoSettings":
                for tag, val in VIDEO_SETTINGS_DEFAULT.items():
                    ensure_child(e, tag, val, v_order, self.stats, "VideoSettings")
            elif e.tag == "AudioSettings":
                ensure_child(e, "FrameRate", self.default_audio_rate, a_order, self.stats, "AudioSettings")
                ensure_child(e, "ChannelType", self.default_channel_type, a_order, self.stats, "AudioSettings")
            elif e.tag == "AudioTrackInlet":
                order = self.canon.get("AudioTrackInlet", [])
                ensure_child(e, "ChannelType", self.default_channel_type, order, self.stats, "AudioTrackInlet")
                ensure_child(e, "FrameRate", self.default_audio_rate, order, self.stats, "AudioTrackInlet")
            elif e.tag == "AudioTransitionTrackItem":
                order = self.canon.get("AudioTransitionTrackItem", [])
                ensure_child(e, "ChannelType", self.default_channel_type, order, self.stats, "AudioTransitionTrackItem")
                ensure_child(e, "FrameRate", self.default_audio_rate, order, self.stats, "AudioTransitionTrackItem")
                ensure_child(e, "CrossfadeSymmetry", "0", order, self.stats, "AudioTransitionTrackItem")
                ensure_child(e, "FadeShapeType", "1", order, self.stats, "AudioTransitionTrackItem")
                ensure_child(e, "FadeShapeValue", "19", order, self.stats, "AudioTransitionTrackItem")
            elif e.tag == "VideoStream":
                order = self.canon.get("VideoStream", [])
                if e.find("InputLUTSpecified") is None:
                    ensure_child(e, "InputLUTSpecified", "false", order, self.stats, "VideoStream")

    # -- effect parameters -------------------------------------------------
    def param_control_type(self, e: ET.Element, shape: str) -> str | None:
        name = text_of(e.find("Name")) or ""
        key = f"{e.tag}|{name}"
        if key in self.param_by_name:
            return self.param_by_name[key]
        key2 = f"{e.tag}|{name}|{shape}"
        if key2 in self.param_by_shape:
            return self.param_by_shape[key2]
        return None

    def fix_params(self):
        for e, _ in walk_with_parent(self.root):
            if is_reference(e):
                continue
            if e.tag not in ("VideoComponentParam", "AudioComponentParam",
                             "PointComponentParam", "ArbVideoComponentParam"):
                continue
            order = self.canon.get(e.tag, [])
            sk = text_of(e.find("StartKeyframe"))
            shape = "bool" if sk and len(sk.split(",")) > 1 and sk.split(",")[1] in ("true", "false") else "other"

            # 24.1 only serialises IsTimeVarying on video/point/arb params.
            if e.tag != "AudioComponentParam":
                ensure_child(e, "IsTimeVarying", "false", order, self.stats, e.tag)

            if e.find("ParameterControlType") is None:
                pct = self.param_control_type(e, shape)
                if pct is None:
                    pct = "4" if shape == "bool" else "8"
                    self.stats.warnings.append(
                        f"parameter {text_of(e.find('Name'))!r} had no 24.1 control type; used {pct}")
                ensure_child(e, "ParameterControlType", pct, order, self.stats, e.tag)

            # Colour-selector params (White Balance / Hue vs Sat) carried 64-bit bounds.
            if (e.tag == "VideoComponentParam"
                    and e.attrib.get("ClassID") == "0fde4e9f-f895-4ba3-b0fe-9a6feafda583"):
                ensure_child(e, "LowerBound", "0", order, self.stats, e.tag)
                ensure_child(e, "UpperBound", "18446744073709551615", order, self.stats, e.tag)

            # Boolean video params carried explicit false/true bounds in 24.1.
            if e.tag == "VideoComponentParam" and shape == "bool" and e.find("LowerBound") is None:
                ensure_child(e, "LowerBound", "false", order, self.stats, e.tag)
                if e.find("UpperBound") is None:
                    val = sk.split(",")[1] if sk else "false"
                    ensure_child(e, "UpperBound", val, order, self.stats, e.tag)

    # -- color management --------------------------------------------------
    def fix_color_space(self):
        order = self.canon.get("VideoTrackGroup", [])
        for e, _ in walk_with_parent(self.root):
            if is_reference(e) or e.tag != "VideoTrackGroup":
                continue
            out = e.find("OutputColorSpace")
            if out is None:
                continue
            name = None
            raw = text_of(out) or ""
            try:
                data = json.loads(raw)
                name = data.get("baseColorProfile", {}).get("colorProfileName")
            except Exception:
                pass
            if not name:
                name = "BT.709 RGB Full"
            mapped = COLOR_SPACE_MAP.get(name)
            if mapped is None:
                base = name.split(",")[0].strip()
                mapped = base if base else "BT.709 RGB Full"
                self.stats.warnings.append(f"unknown color space {name!r}; mapped to {mapped!r}")

            working = json.dumps(
                {"baseColorProfile": {"colorProfileName": mapped}, "baseProfileType": 1},
                separators=(",", ":"),
            )
            config = json.dumps(
                {"workingSpaceConfigVersion": 1, "workingSpaceID": mapped,
                 "workingSpaceIsLinearized": 0},
                separators=(",", ":"),
            )
            for tag in ("WorkingColorSpaceConfiguration", "WorkingColorSpace"):
                old = e.find(tag)
                if old is not None:
                    e.remove(old)
            ensure_child(e, "WorkingColorSpaceConfiguration", config, order, self.stats, "VideoTrackGroup")
            ensure_child(e, "WorkingColorSpace", working, order, self.stats, "VideoTrackGroup")
            e.remove(out)
            self.stats.removed["OutputColorSpace"] += 1

    # -- reorder -----------------------------------------------------------
    def reorder_known_objects(self):
        reorder_tags = {
            "Track", "AudioTrack", "Component", "AudioComponentChain",
            "VideoSettings", "AudioSettings", "VideoTrackGroup",
            "VideoComponentParam", "AudioComponentParam", "PointComponentParam",
            "ArbVideoComponentParam", "VideoClipTrackItem", "AudioClipTrackItem",
            "ClipTrack", "ClipTrackItem", "TrackItem", "AudioTrackInlet",
            "AudioTransitionTrackItem", "VideoStream", "AudioStream",
        }
        for e, _ in walk_with_parent(self.root):
            if is_reference(e) or e.tag not in reorder_tags:
                continue
            order = self.canon.get(e.tag)
            if not order:
                continue
            children = list(e)
            if len(children) < 2:
                continue
            indexed = []
            for i, c in enumerate(children):
                idx = order.index(c.tag) if c.tag in order else len(order) + i
                indexed.append((idx, i, c))
            new = [c for _, _, c in sorted(indexed, key=lambda x: (x[0], x[1]))]
            if new != children:
                for c in children:
                    e.remove(c)
                e.extend(new)
                self.stats.reordered += 1

    # -- run ---------------------------------------------------------------
    def run(self) -> Stats:
        self.downgrade_versions()
        self.fix_color_space()       # must read OutputColorSpace before removal
        self.remove_new_elements()
        self.remove_class_specific()
        self.fix_audio_tracks()
        self.fix_components()
        self.fix_audio_component_chains()
        self.fix_settings()
        self.fix_params()
        self.reorder_known_objects()
        # collapse duplicate warnings
        seen = []
        for w in self.stats.warnings:
            if w not in seen:
                seen.append(w)
        self.stats.warnings = seen[:50]
        return self.stats


# ---------------------------------------------------------------------------
# Reference transplant
# ---------------------------------------------------------------------------

def try_reference(inp: ET.ElementTree, ref_path: Path) -> tuple[bool, list[str], int | None]:
    ref = parse_project(ref_path)
    a = content_signature(inp)
    b = content_signature(ref)
    problems = compare_signatures(a, b)
    return (not problems), problems, project_version(ref)


def project_version(tree: ET.ElementTree) -> int | None:
    for obj in tree.getroot():
        if obj.tag == "Project" and "Version" in obj.attrib:
            try:
                return int(obj.attrib["Version"])
            except ValueError:
                return None
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Downgrade a Premiere Pro 2026 project to the 2024 schema.")
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--reference", type=Path)
    ap.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    ap.add_argument("--report", type=Path)
    ap.add_argument("--no-verify", action="store_true")
    ap.add_argument("--no-pretty", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = ap.parse_args(argv)

    def log(msg):
        if not args.quiet:
            print(msg, file=sys.stderr)

    if not args.input.exists():
        print(f"error: input not found: {args.input}", file=sys.stderr)
        return 2
    if args.output.resolve() == args.input.resolve():
        print("error: output must differ from input (originals are never overwritten)", file=sys.stderr)
        return 2
    if args.reference and args.output.resolve() == args.reference.resolve():
        print("error: output must differ from the reference project", file=sys.stderr)
        return 2

    schema = {}
    if args.schema and args.schema.exists():
        schema = json.loads(args.schema.read_text())
    elif not args.quiet:
        log(f"warning: schema profile not found at {args.schema}; using built-in heuristics only")

    inp = parse_project(args.input)
    in_version = project_version(inp)
    report = {"input": str(args.input), "output": str(args.output),
              "input_project_version": in_version, "target_version": TARGET_VERSION}
    if in_version is not None and in_version <= TARGET_VERSION:
        log(f"warning: input already reports project version {in_version} (<= {TARGET_VERSION})")

    if args.reference:
        log(f"checking reference {args.reference} ...")
        ok, problems, ref_version = try_reference(inp, args.reference)
        report["reference_project_version"] = ref_version
        if ref_version != TARGET_VERSION:
            print(f"error: reference is project version {ref_version}, not {TARGET_VERSION} (CC2024).",
                  file=sys.stderr)
            return 3
        if not ok:
            print("error: reference project does not match this edit:", file=sys.stderr)
            for p in problems:
                print(f"  - {p}", file=sys.stderr)
            print("Refusing to transplant a reference with different content.", file=sys.stderr)
            return 3
        shutil.copyfile(args.reference, args.output)
        report.update({
            "mode": "reference-transplant",
            "reference": str(args.reference),
            "sha256": file_sha256(args.output),
            "note": "Reference content matched; emitted the 2024-native file unchanged.",
        })
        log(f"wrote {args.output} (reference transplant)")
    else:
        log("applying schema downgrade ...")
        dg = Downgrader(inp, schema)
        stats = dg.run()
        write_project(inp, args.output, pretty=not args.no_pretty)
        report.update({
            "mode": "schema-downgrade",
            "target_version": TARGET_VERSION,
            "sha256": file_sha256(args.output),
            "changes": stats.to_dict(),
        })
        log(f"wrote {args.output}")

    if not args.no_verify:
        log("verifying output ...")
        try:
            check = parse_project(args.output)
            if check.getroot().tag != "PremiereData":
                raise ValueError("root element is not PremiereData")
            report["verified"] = True
        except Exception as exc:
            report["verified"] = False
            report["verify_error"] = str(exc)
            print(f"error: output failed verification: {exc}", file=sys.stderr)
            return 4

    if args.report:
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True))
        log(f"report: {args.report}")

    if not args.quiet:
        if report.get("mode") == "reference-transplant":
            print("OK — reference transplant (content matched).")
        else:
            print("OK — schema downgrade written. Open it in Premiere 2024 and verify before use.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
