# Camera model catalogs

One JSON file per vendor, each a flat `{"CODE": "Product Name"}` object mapping
a bare internal model code (what EXIF `Model` and some video vendor atoms
contain) to the retail product name used in camera labels.

- The filename (minus `.json`) identifies the vendor for organization/review
  purposes only — it is not read by the loader. Lookup is purely by
  uppercased code.
- Codes must be globally unique across every file in this directory. A
  duplicate code in two vendor files is a data bug, not a valid override —
  `CameraModelCatalogLoaderTests.testNoDuplicateCodesAcrossVendorFiles`
  enforces this.
- Lookup is case-insensitive: the loader trims and uppercases every key, so
  keys may be written in any case, but uppercase is the convention used here.
- Every entry requires hand-verification against real camera output — there
  is no way to auto-derive a bare code -> marketing name mapping.

## Provenance notes

- **DJI**: EXIF `Model` on photos is always the bare code. The code<->name
  pairing is confirmed via the hidden `ExifIFD:UniqueCameraModel` tag, e.g.
  `"DJI AC003 OsmoAction4"`. Product names here deliberately exclude the
  "DJI" prefix, matching what `StripDJIManufacturerPrefixRule` strips from
  the `"DJI <name>"` form some video paths produce, so both vocabularies
  converge on the same label.
- **Samsung**: `SM-A546B` (photo/video model number) shares no substring with
  `Galaxy A54 5G` (marketing name) — mapped by hand since neither string is
  derivable from the other.
