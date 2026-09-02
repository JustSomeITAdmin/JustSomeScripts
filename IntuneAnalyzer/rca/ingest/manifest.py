"""Parse the package's results.xml manifest.

results.xml looks like:

    <Collection HRESULT="0">
      <ID>9022baef-...</ID>
      <RegistryKey HRESULT="-2147024895">HKLM\\SOFTWARE\\...</RegistryKey>
      <Command HRESULT="0">%windir%\\system32\\ipconfig.exe /all</Command>
      ...
    </Collection>

For Phase 0 we extract the collection-level identity (ID + HRESULT). The
per-item HRESULTs are already encoded in the entry names (see classify.py);
richer manifest cross-referencing can come later.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass


@dataclass
class Manifest:
    collection_id: str | None
    hresult: int | None


def parse_manifest(xml_bytes: bytes) -> Manifest:
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return Manifest(None, None)

    hresult = None
    if (raw := root.get("HRESULT")) is not None:
        try:
            hresult = int(raw)
        except ValueError:
            hresult = None

    collection_id = None
    id_el = root.find("ID")
    if id_el is not None and id_el.text:
        collection_id = id_el.text.strip()

    return Manifest(collection_id, hresult)
