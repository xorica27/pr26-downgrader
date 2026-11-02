import gzip
import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "app" / "prproj_downgrade.py"
SCHEMA = ROOT / "app" / "schema42.json"

# Minimal synthetic v45 project. Adobe class IDs only; no real project data.
SYNTHETIC = """<?xml version="1.0" encoding="UTF-8" ?>
<PremiereData Version="3">
\t<Project ObjectID="1" ClassID="62ad66dd-0dcd-42da-a660-6d8fbde94876" Version="45">
\t\t<Node Version="1"><Properties Version="1"/></Node>
\t</Project>
\t<ProjectSettings ObjectID="2" ClassID="50c16708-a1a1-4d2f-98d5-4e283ae28353" Version="21">
\t\t<ColorAwareEffectsEnabled>true</ColorAwareEffectsEnabled>
\t</ProjectSettings>
\t<VideoTrackGroup ObjectID="3" ClassID="9e9abf7a-0918-49c2-91ae-991b5dde77bb" Version="13">
\t\t<TrackGroup Version="1"><FrameRate>5080320000</FrameRate></TrackGroup>
\t\t<PixelAspectRatio>1,1</PixelAspectRatio>
\t\t<ColorManagementSettings>{"autoToneMapEnabled":true}</ColorManagementSettings>
\t\t<FrameRect>0,0,1920,1080</FrameRect>
\t\t<OutputColorSpace>{"baseColorProfile":{"colorProfileName":"BT.709,8-bit,Display-Referred"},"baseProfileType":1}</OutputColorSpace>
\t\t<FieldType>0</FieldType>
\t\t<AllowLinearCompositing>true</AllowLinearCompositing>
\t</VideoTrackGroup>
\t<VideoClipTrack ObjectUID="11111111-1111-4111-8111-111111111111" ClassID="f68dcd81-8805-11d5-af2d-9bfa89d4ddd4" Version="1">
\t\t<ClipTrack Version="2">
\t\t\t<Track Version="4">
\t\t\t\t<Node Version="1"><Properties Version="1"/></Node>
\t\t\t\t<ID>1</ID>
\t\t\t\t<MediaType>228cda18-3625-4d2d-951e-348879e4ed93</MediaType>
\t\t\t\t<Index>0</Index>
\t\t\t</Track>
\t\t\t<ClipItems Version="3"/>
\t\t\t<TransitionItems Version="3"/>
\t\t</ClipTrack>
\t</VideoClipTrack>
\t<AudioClipTrack ObjectUID="22222222-2222-4222-8222-222222222222" ClassID="097f6203-99ae-11d5-84f2-8cf14bde7040" Version="7">
\t\t<ClipTrack Version="2">
\t\t\t<Track Version="4">
\t\t\t\t<Node Version="1"><Properties Version="1"/></Node>
\t\t\t\t<ID>2</ID>
\t\t\t\t<MediaType>80b8e3d5-6dca-4195-aefb-cb5f407ab009</MediaType>
\t\t\t\t<Index>0</Index>
\t\t\t</Track>
\t\t\t<ClipItems Version="3"/>
\t\t\t<TransitionItems Version="3"/>
\t\t</ClipTrack>
\t\t<AudioTrack Version="12">
\t\t\t<ComponentOwner Version="1"><Components ObjectRef="20"/></ComponentOwner>
\t\t\t<Panner ObjectRef="21"/>
\t\t\t<ID>33333333-3333-4333-8333-333333333333</ID>
\t\t\t<SubType>1</SubType>
\t\t\t<Assign>1</Assign>
\t\t\t<NextPannerID>4294967279</NextPannerID>
\t\t</AudioTrack>
\t</AudioClipTrack>
\t<VideoComponentParam ObjectID="4" ClassID="cc12343e-f113-4d3b-ae05-b287db77d461" Version="10">
\t\t<Name>Basic Correction</Name>
\t\t<ParameterID>2</ParameterID>
\t\t<StartKeyframe>-91445760000000000,false,0,0,0,0,0,0</StartKeyframe>
\t\t<UpperBound>false</UpperBound>
\t</VideoComponentParam>
\t<AudioComponentParam ObjectID="5" ClassID="a714635e-a628-4b27-9d59-77eba47dbc1a" Version="10">
\t\t<Name>Volume</Name>
\t\t<UnitsString>dB</UnitsString>
\t\t<Timestamp>123456789</Timestamp>
\t</AudioComponentParam>
\t<AudioComponentChain ObjectID="6" ClassID="3cb131d1-d3c0-47ae-a19a-bdf75ea11674" Version="4">
\t\t<DefaultVol>true</DefaultVol>
\t\t<ComponentChain Version="3"/>
\t\t<AudioChannelLayout>[{"channellabel":100}]</AudioChannelLayout>
\t\t<ChannelType>1</ChannelType>
\t</AudioComponentChain>
\t<VideoSettings ObjectID="7" ClassID="58474264-30c4-43a2-bba5-dc0812df8a3a" Version="10"/>
\t<AudioSettings ObjectID="8" ClassID="6baf5521-b132-4634-840e-13cec5bc86a4" Version="8"/>
\t<AudioTrackInlet ObjectID="9" ClassID="be3af080-e8c6-11d5-abc4-a1c6d5dee670" Version="4"/>
\t<AudioTransitionTrackItem ObjectID="10" ClassID="23f687b6-9c5a-42f4-bea1-e7b3e28e7082" Version="4"/>
\t<VideoStream ObjectID="11" ClassID="a36e4719-3ec6-4a0c-ab11-8b4aab377aa5" Version="22">
\t\t<OriginalColorSpace>{"baseColorProfile":{"colorProfileName":"BT.709"}}</OriginalColorSpace>
\t</VideoStream>
\t<MasterClip ObjectID="12" ClassID="fb11c33a-b0a9-4465-aa94-b6d5db2628cf" Version="12">
\t\t<Node Version="1"><ID>4</ID><Properties Version="1"/></Node>
\t</MasterClip>
\t<Sequence ObjectUID="44444444-4444-4444-8444-444444444444" ClassID="6a15d903-8739-11d5-af2d-9b7855ad8974" Version="12">
\t\t<Node Version="1"><Properties Version="1"/></Node>
\t\t<Name>Test Sequence</Name>
\t</Sequence>
</PremiereData>
"""


def child(parent, tag):
    return parent.find(tag)


def children(parent):
    return {c.tag: c for c in parent}


class DowngradeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.src = self.dir / "input_2026.prproj"
        self.out = self.dir / "output_2024.prproj"
        self.report = self.dir / "report.json"
        with gzip.open(self.src, "wb") as f:
            f.write(SYNTHETIC.encode("utf-8"))
        result = subprocess.run(
            [sys.executable, str(ENGINE), str(self.src), str(self.out),
             "--schema", str(SCHEMA), "--report", str(self.report), "--quiet"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        with gzip.open(self.out, "rb") as f:
            self.tree = ET.parse(f)
        self.root = self.tree.getroot()
        self.objects = {o.attrib.get("ObjectID") or o.attrib.get("ObjectUID"): o
                        for o in self.root}
        self.report_data = json.loads(self.report.read_text())

    def tearDown(self):
        self.tmp.cleanup()

    def test_project_version(self):
        self.assertEqual(self.objects["1"].attrib["Version"], "42")

    def test_colour_space_converted(self):
        vtg = self.objects["3"]
        tags = children(vtg)
        self.assertNotIn("OutputColorSpace", tags)
        self.assertIn("WorkingColorSpace", tags)
        self.assertIn("WorkingColorSpaceConfiguration", tags)
        self.assertIn("BT.709 RGB Full", tags["WorkingColorSpace"].text)

    def test_track_flags_restored(self):
        vct = self.objects["11111111-1111-4111-8111-111111111111"]
        track = vct.find("ClipTrack/Track")
        self.assertEqual(track.attrib["Version"], "3")
        self.assertEqual(child(track, "IsLocked").text, "false")
        self.assertEqual(child(track, "IsMuted").text, "false")
        self.assertEqual(child(track, "IsSyncLocked").text, "true")

    def test_audio_track_fields_restored(self):
        act = self.objects["22222222-2222-4222-8222-222222222222"]
        audio = act.find("AudioTrack")
        self.assertEqual(audio.attrib["Version"], "11")
        for tag in ("ChannelType", "FrameRate", "AutomationMode", "SubType",
                    "Assign", "Solo", "MutedBySolo"):
            self.assertIsNotNone(child(audio, tag), tag)
        self.assertEqual(child(act, "RecordChannel").text, "0")

    def test_video_param_fields_restored(self):
        p = self.objects["4"]
        self.assertEqual(p.attrib["Version"], "9")
        self.assertEqual(child(p, "IsTimeVarying").text, "false")
        self.assertEqual(child(p, "ParameterControlType").text, "11")
        self.assertEqual(child(p, "LowerBound").text, "false")
        self.assertEqual(child(p, "UpperBound").text, "false")

    def test_audio_param_has_no_is_time_varying(self):
        p = self.objects["5"]
        self.assertEqual(p.attrib["Version"], "9")
        self.assertIsNone(child(p, "IsTimeVarying"))
        self.assertIsNotNone(child(p, "ParameterControlType"))

    def test_audio_chain_fields_restored(self):
        chain = self.objects["6"]
        self.assertEqual(chain.attrib["Version"], "3")
        self.assertIsNotNone(child(chain, "FrameRate"))
        self.assertIsNotNone(child(chain, "AutomationMode"))

    def test_settings_restored(self):
        vs = self.objects["7"]
        self.assertEqual(vs.attrib["Version"], "9")
        for tag in ("FrameRate", "FrameSize", "PixelAspectRatio", "MaximumBitDepth"):
            self.assertIsNotNone(child(vs, tag), tag)
        aud = self.objects["8"]
        self.assertEqual(aud.attrib["Version"], "7")
        self.assertIsNotNone(child(aud, "FrameRate"))

    def test_new_only_fields_removed(self):
        self.assertIsNone(child(self.objects["11"], "OriginalColorSpace"))
        self.assertIsNone(child(self.objects["2"], "ColorAwareEffectsEnabled"))
        self.assertIsNone(self.objects["12"].find("Node/ID"))

    def test_report(self):
        self.assertEqual(self.report_data["mode"], "schema-downgrade")
        self.assertEqual(self.report_data["target_version"], 42)
        self.assertTrue(self.report_data["verified"])


if __name__ == "__main__":
    unittest.main()
