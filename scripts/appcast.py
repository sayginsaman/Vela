#!/usr/bin/env python3
"""Append a release to appcast.xml.

  scripts/appcast.py <version> <build> <dmg-path> <download-url> <ed-signature> [release-notes-url]

The EdDSA signature comes from Sparkle's sign_update. Entries are kept newest-first.
"""
import os, sys, xml.etree.ElementTree as ET
from email.utils import format_datetime
from datetime import datetime, timezone

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

version, build, dmg, url, signature = sys.argv[1:6]
notes = sys.argv[6] if len(sys.argv) > 6 else f"https://github.com/sayginsaman/Vela/releases/tag/v{version}"
path = os.path.join(os.path.dirname(__file__), "..", "appcast.xml")

tree = ET.parse(path)
channel = tree.getroot().find("channel")
for item in channel.findall("item"):
    if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version:
        channel.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Vela {version}"
ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = notes
ET.SubElement(item, "enclosure", {
    "url": url,
    "length": str(os.path.getsize(dmg)),
    "type": "application/octet-stream",
    f"{{{SPARKLE}}}edSignature": signature,
})
channel.insert(list(channel).index(channel.find("item")) if channel.find("item") is not None else len(list(channel)), item)
ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
print(f"appcast: added {version} ({build})")
