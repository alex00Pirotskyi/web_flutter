# Signal Analysis Studio V4.1

V4.1 is a focused last-mile release on top of the V4 product/performance architecture.

## What changed

### 1. Sign-aware normalization axis

Normalization no longer always forces the Y axis to `-1.1 .. +1.1`.

For the currently visible features:

- non-negative data only -> `0 .. +1.1`
- non-positive data only -> `-1.1 .. 0`
- mixed positive/negative data -> `-1.1 .. +1.1`
- all-zero data -> `0 .. 1.0`

The analyzer stores per-column minimum/maximum metadata during CSV parsing, including the Web Worker parse path, so the chart does not rescan full columns during every rebuild.

### 2. Readability pass

The application now has a minimum 1.15x text scale while preserving larger platform accessibility scaling. Supporting UI geometry was increased as well:

- wider workspace navigation
- taller navigation cards
- larger top bar
- wider workspace panel
- taller Explorer and Feature rows
- larger chart axis/title/tooltip typography
- larger compact action buttons

The index-grid collision calculation was updated for the larger tabular index labels, so readability does not reintroduce overlapping X-axis labels.

### 3. Apply YAML -> Download ZIP

Explorer now contains a new action:

`Apply YAML  ->  Download ZIP`

It applies the complete current annotation state to every loaded CSV and downloads a new ZIP. Original uploaded files and the current in-app annotation session are not modified.

#### Required processing order

For every CSV:

1. Parse the original CSV rows.
2. Apply all logical Boolean edits (`0/1`) using the **original zero-based sample indexes**.
3. Remove rows covered by `invalid_ranges`, also using the original sample indexes.
4. Write the processed CSV into a new output ZIP.
5. Add `applied_tag_info.yaml` to the ZIP as an audit manifest.

This ordering is intentional. Removing invalid rows first would shift subsequent row indexes and make logical YAML ranges target the wrong samples.

### Output ZIP behavior

- All loaded CSVs are included, not only the currently selected file.
- ZIP-internal paths are preserved where possible.
- Duplicate output paths are automatically suffixed (`__2`, `__3`, ...).
- Unsafe `.` / `..` path segments are removed from output archive paths.
- The generated ZIP contains `applied_tag_info.yaml`.
- The Web Worker performs the normal transformation and ZIP assembly path to avoid blocking Flutter's UI thread.
- A Dart fallback remains available if the worker is unavailable.

## Required project files

Copy:

- `lib/main.dart`
- `web/data_worker.js`

The worker file is required for the intended large-file responsiveness and Apply-YAML export performance.

## Validation completed in this environment

- JavaScript syntax check: passed
- Web Worker CSV transformation smoke test: passed
- Logical-edit-before-invalid-removal ordering test: passed
- Stored ZIP construction test: passed
- ZIP CRC/integrity test: passed
- Worker min/max/normalization metadata test: passed
- Dart lexical delimiter/string structure check: passed

A real `flutter analyze` / Chrome build could not be run in this container because Flutter/Dart SDK binaries are not installed here.
