# Upload Streaming Example

Streaming uploads, bytes or text. A binary file is kept exactly as sent; CSV
imports are decoded as they arrive by the client's charset and parsed as real
CSV; NDJSON is read a line at a time; a lenient transform shouts text back.
Nothing is held in memory whole.

## Run

```bash
pagi-server --app examples/upload-streaming/app.pl --port 5000
```

## What it shows

- **Bytes stay bytes.** `store_file` streams the body without `decode`, so
  an archive, an image or anything binary arrives exactly as sent; the
  response carries its size and SHA-256.
- **Text is decoded as it streams** with
  `body_stream(decode => $request->charset // 'UTF-8')`: the client's
  declared charset, UTF-8 when it declares none. A character split across
  chunks waits for its other half; one bad byte does not hold back the rest.
- **`strict` decides what bad bytes mean.**
  - `import_csv` turns it **on**: every row is stored, so bytes that are not
    valid in the declared charset are the client's 400. A binary file posted
    to this text route fails at once instead of becoming garbage text.
  - `shout` leaves it **off**: a stray U+FFFD does no harm in a transform.
- **A charset the stream cannot decode is the client's 415**, as for
  `$request->text`: one Encode does not know, or ISO-2022/UTF-7, which
  Encode decodes only line by line. To take another path, catch the
  `PAGI::Exception::RequestBody` at the `body_stream` call.
- **A hang-up is not bad input.** A client that disconnects mid-upload ends
  the stream early and `$stream->truncated` is true. The example removes a
  partial or empty file rather than keep it.
- **The BOM.** Excel's "CSV UTF-8" and "Unicode Text" (`utf-16le`) start
  with a byte-order mark, which is text in those encodings and arrives as
  U+FEFF. `strip_bom => 1` drops it, so the first column reads `name`, not
  `"\x{FEFF}name"`. Plain `utf-16`/`utf-32` consume the mark themselves.
- **Real CSV.** The decoded text is spooled as UTF-8 and parsed with
  Text::CSV: a quoted field may hold a newline, so CSV is not one record per
  line. A malformed file is the client's 400.
- **NDJSON by line.** `/events` reads one JSON document per line with
  `each_line`, without holding the body. A line ends at `\n` (a `\r` before
  it is dropped); one longer than `max_line_length` (64 KiB unless the route
  sets it) is the client's 413.
- **A safe file name.** `{name:[\w-]+(?:\.[\w-]+)*}` allows letters,
  digits, `-`, `_` and single dots between them: no `/`, no `.` or `..`, no
  leading or trailing dot. Anything else is a 404.
- **The size cap.** `max_bytes` stops an upload at 50 MB. Going over it is
  the client's 413 (`PAGI::Exception::RequestBody`, `too_large`); the example
  removes the partial file before rethrowing it, and Compose answers.

## Try

```bash
curl -i -T archive.zip localhost:5000/files/archive.zip
curl -i --data-binary @people.csv -H 'Content-Type: text/csv; charset=windows-1252' localhost:5000/import
iconv -f utf-8 -t utf-16 people.csv | curl -i --data-binary @- -H 'Content-Type: text/csv; charset=utf-16' localhost:5000/import
curl -i --data-binary $'{"type":"a"}\n{"type":"b"}\n' localhost:5000/events
curl -i --data-binary 'hello wörld' -H 'Content-Type: text/plain; charset=utf-8' localhost:5000/shout
curl -i --data-binary @archive.zip -H 'Content-Type: text/csv; charset=utf-8' localhost:5000/import   # 400
curl -i --data-binary 'a' -H 'Content-Type: text/csv; charset=x-bogus' localhost:5000/import          # 415
```

## API

- `PUT /files/{name}` - store the body as a file: 201 with `name`, `bytes`
  and `sha256`; 400 when empty or cut short
- `POST /import` - read a CSV in any charset Encode can stream:
  `{"columns": [...], "rows": N}`, the header and the number of data rows;
  400 for bytes invalid in that charset or malformed CSV; 415 for a charset
  it cannot decode
- `POST /events` - read NDJSON: `{"events": N, "types": [...]}`
- `POST /shout` - the text, upper-cased, streamed back as UTF-8

## See also

- `PAGI::Request` `body_stream` - bytes or text, and when to use `strict`
- `PAGI::Request::BodyStream` `next_line` and `each_line`
- `PAGI::Utils::TextDecoder` - the decoder underneath, for any other byte
  source
- `PAGI::Tools::Cookbook`, "A huge upload in a legacy encoding" - spool to
  disk, then read through PerlIO's `:encoding`
- `examples/gut-check/07-upload-relay.pl` - the same three ideas side by
  side with Starlette
