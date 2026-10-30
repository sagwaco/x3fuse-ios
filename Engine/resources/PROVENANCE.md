# Engine resources

## opcodes/

DNG flat-field lens corrections (`OpcodeList3` blobs) for the DP1, DP2 and
DP3 Merrill and the SD1 Merrill with the 30mm lens. x3f-core embeds the file
that matches the camera and aperture when a DNG is exported without highlight
recovery. Bundle this folder in the app as a folder named `opcodes`.

- Source: https://github.com/sagwaco/x3fuse, path `src-tauri/resources/opcodes`
- Commit: `737688ff255c0b0e735fa374ff764ebb89517818`. Unmodified, 69 files.
  The same files are in https://github.com/sagwaco/x3fuse-core `opcodes/`.
- License: the x3fuse-core `opcodes/README.md` says these calibration blobs
  were freely distributed by the Sigma photographer community with no
  license terms, and that redistribution is allowed.

## film-grain.json

spektrafilm grain RMS values per film stock, which the desktop look picker
uses when a stock is selected.

- Source: https://github.com/sagwaco/x3fuse, path `src/shared/film-grain.json`
- Commit: `737688ff255c0b0e735fa374ff764ebb89517818`. Unmodified.
- License: GPL-3.0-only with the x3fuse project; the values come from
  spektrafilm presets (CC BY-SA 4.0, see `Vendor/x3f-render/NOTICE`).
