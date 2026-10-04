import Foundation
import zlib

// History import: the export FILES, read on this phone (4 Oct 2026).
//
// A TV Time export is the whole account — the email, comments, IP history beside the watch log —
// and a MyAnimeList export carries scores, tags and notes. None of that is this app's to have, so
// the files never leave the device: they are opened here, the rows that ARE watch history are kept,
// and only those go to the server (`POST /me/import/preview`). Hence a zip reader and a CSV reader
// in an app that otherwise has neither: both are small, both are pure, and `ImportRegression`
// checks them against the real shapes.
//
// The shapes (verified against real exports, 2026 — the open-source importers' fixtures):
//   MyAnimeList — `animelist_….xml.gz`: <anime> rows with series_animedb_id, series_title,
//     my_watched_episodes, my_status.
//   TV Time, the GDPR zip — `tracking-prod-records-v2.csv`: one row per event, told apart by `key`
//     (`watch-episode-…`, `rewatch-episode-…`, `user-series-…`); `s_id` is the show's TheTVDB id.
//   TV Time, "export my data" — `tvtime-series-episodes.csv` (series_tvdb_id, season, episode,
//     is_watched, watched_at) and `tvtime-series.csv` (tvdb_id, title, status).

/// What a file could not be read as — said in the sheet in the viewer's words.
enum ImportFileError: Error, Equatable {
    /// Not a file this importer knows (the wrong export, or something else entirely).
    case unrecognised
    /// A password-protected zip: its entries cannot be read without the password.
    case encrypted
    /// The right kind of file, with no watch history in it.
    case empty
}

// MARK: - The rows that go to the server

/// One MyAnimeList row (`POST /me/import/preview`, `source: mal`).
struct ImportMalRow: Encodable, Equatable, Sendable {
    let malId: Int
    let status: String
    let watched: Int
    let title: String?
}

/// One TV Time show (`source: tvtime`): its seasons and the episodes seen in each.
struct ImportTvShow: Encodable, Equatable, Sendable {
    struct Season: Encodable, Equatable, Sendable {
        let number: Int
        let watched: [Int]
    }
    let tvdbId: Int?
    let title: String
    let seasons: [Season]
    let followed: Bool
    let forLater: Bool
    let archived: Bool
    /// The newest watch, ms epoch — how the server tells "watching" from "stopped long ago".
    let lastWatchedAt: Int64?
}

// MARK: - gzip

/// Bounded raw-DEFLATE/gzip decoding. zlib validates gzip headers, CRC and length rather than
/// accepting the intact prefix of a truncated export. The cap applies to actual inflated bytes.
private enum ImportInflate {
    static let limit = 64 * 1024 * 1024

    static func decode(_ data: Data, gzip: Bool) -> Data? {
        guard data.count <= limit else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, gzip ? 31 : -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return data.withUnsafeBytes { input -> Data? in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 32_768)
            while true {
                let status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard output.count + count <= limit else { return nil }
                output.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END { return stream.avail_in == 0 ? output : nil }
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else { return nil }
            }
        }
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
}

enum Gzip {
    static func isGzip(_ data: Data) -> Bool { data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b }
    static func inflate(_ data: Data) -> Data? { ImportInflate.decode(data, gzip: true) }
}

// MARK: - zip

/// A zip archive, read: its entries by name, each inflated on request. Stored and DEFLATE entries
/// (every export uses one or the other); no zip64, no spanning.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let encrypted: Bool
        let compressedSize: Int
        let size: Int
        let crc: UInt32
        let localOffset: Int
    }

    private let data: Data
    let entries: [Entry]

    static func isZip(_ data: Data) -> Bool {
        data.count > 22 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4b
    }

    init?(_ data: Data) {
        let bytes = Data(data)   // rebased to index 0
        guard Self.isZip(bytes) else { return nil }
        // The end-of-central-directory record: within the last 64 KiB (it may carry a comment).
        let floor = max(0, bytes.count - 65_557)
        var eocd = bytes.count - 22
        while eocd >= floor, Self.u32(bytes, eocd) != 0x0605_4b50 { eocd -= 1 }
        guard eocd >= floor, eocd + 22 + Int(Self.u16(bytes, eocd + 20)) == bytes.count,
              Self.u16(bytes, eocd + 4) == 0, Self.u16(bytes, eocd + 6) == 0,
              Self.u16(bytes, eocd + 8) == Self.u16(bytes, eocd + 10) else { return nil }
        let count = Int(Self.u16(bytes, eocd + 10))
        var cursor = Int(Self.u32(bytes, eocd + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, Self.u32(bytes, cursor) == 0x0201_4b50 else { return nil }
            let nameLength = Int(Self.u16(bytes, cursor + 28))
            let extra = Int(Self.u16(bytes, cursor + 30)), comment = Int(Self.u16(bytes, cursor + 32))
            guard cursor + 46 + nameLength + extra + comment <= eocd else { return nil }
            let name = String(decoding: bytes.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), as: UTF8.self)
            entries.append(Entry(name: name,
                                 method: Self.u16(bytes, cursor + 10),
                                 encrypted: Self.u16(bytes, cursor + 8) & 1 != 0,
                                 compressedSize: Int(Self.u32(bytes, cursor + 20)),
                                 size: Int(Self.u32(bytes, cursor + 24)),
                                 crc: Self.u32(bytes, cursor + 16),
                                 localOffset: Int(Self.u32(bytes, cursor + 42))))
            cursor += 46 + nameLength + extra + comment
        }
        self.data = bytes
        self.entries = entries
    }

    /// The first entry whose file name (its last path component) is `name`.
    func entry(named name: String) -> Entry? {
        entries.first { ($0.name as NSString).lastPathComponent.lowercased() == name.lowercased() }
    }

    func contents(of entry: Entry) -> Data? {
        let at = entry.localOffset
        guard !entry.encrypted, entry.size <= ImportInflate.limit, at + 30 <= data.count, Self.u32(data, at) == 0x0403_4b50 else { return nil }
        let start = at + 30 + Int(Self.u16(data, at + 26)) + Int(Self.u16(data, at + 28))
        guard start + entry.compressedSize <= data.count else { return nil }
        let body = data.subdata(in: start..<(start + entry.compressedSize))
        let output: Data?
        switch entry.method {
        case 0: output = body
        case 8: output = ImportInflate.decode(body, gzip: false)
        default: return nil
        }
        guard let output, output.count == entry.size, ImportInflate.checksum(output) == entry.crc else { return nil }
        return output
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) | UInt16(d[at + 1]) << 8 }
    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }
}

// MARK: - CSV

/// RFC 4180, read a row at a time: quoted fields, doubled quotes, commas and newlines inside
/// quotes. The first row is the header; `body` gets each later row as its columns by name.
enum CSVRows {
    static func forEach(in data: Data, _ body: (_ row: [String: String]) -> Void) {
        var header: [String]?
        var field = [UInt8](), fields = [String]()
        var quoted = false, pendingQuote = false
        func endField() {
            fields.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func endRow() {
            endField()
            defer { fields.removeAll(keepingCapacity: true) }
            guard let header else {
                // A byte-order mark is not part of the first column's name.
                header = fields.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \r")) }
                return
            }
            if fields.count == 1, fields[0].isEmpty { return }
            var row = [String: String](minimumCapacity: header.count)
            for (i, name) in header.enumerated() where i < fields.count && !fields[i].isEmpty { row[name] = fields[i] }
            body(row)
        }
        for byte in data {
            if quoted {
                if pendingQuote {
                    pendingQuote = false
                    if byte == 0x22 { field.append(byte); continue }   // "" → a quote
                    quoted = false                                       // the quote closed the field
                } else if byte == 0x22 {
                    pendingQuote = true
                    continue
                } else {
                    field.append(byte)
                    continue
                }
            }
            switch byte {
            case 0x22 where field.isEmpty: quoted = true
            case 0x2c: endField()
            case 0x0a: endRow()
            case 0x0d: break
            default: field.append(byte)
            }
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }
    }
}

// MARK: - MyAnimeList

/// MyAnimeList's anime export: the XML, or the `.xml.gz` it is downloaded as.
enum MalExport {
    static func parse(_ file: Data) throws -> [ImportMalRow] {
        guard file.count <= ImportInflate.limit else { throw ImportFileError.unrecognised }
        let xml = Gzip.isGzip(file) ? Gzip.inflate(file) : file
        guard let xml, !xml.isEmpty else { throw ImportFileError.unrecognised }
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        guard parser.parse() else { throw ImportFileError.unrecognised }
        guard reader.sawList else { throw ImportFileError.unrecognised }
        guard !reader.rows.isEmpty else { throw ImportFileError.empty }
        return reader.rows
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var rows: [ImportMalRow] = []
        var sawList = false
        private var current: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "myanimelist" { sawList = true }
            if name == "anime" { current = [:] }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "anime" {
                if let row = current, let id = Int(row["series_animedb_id"] ?? ""), id > 0 {
                    rows.append(ImportMalRow(malId: id,
                                             status: row["my_status"] ?? "",
                                             watched: max(0, Int(row["my_watched_episodes"] ?? "") ?? 0),
                                             title: row["series_title"]))
                }
                current = nil
            } else if current != nil {
                current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

// MARK: - TV Time

/// A TV Time export: the GDPR zip, the newer "export my data" zip, or a file from inside either.
enum TvTimeExport {
    static func parse(_ file: Data, fileName: String) throws -> [ImportTvShow] {
        guard file.count <= ImportInflate.limit else { throw ImportFileError.unrecognised }
        var builder = Builder()
        if ZipReader.isZip(file) {
            guard let zip = ZipReader(file) else { throw ImportFileError.unrecognised }
            let wanted = ["tracking-prod-records-v2.csv", "tvtime-series-episodes.csv", "tvtime-series.csv"]
            let found = wanted.compactMap { zip.entry(named: $0) }
            guard !found.isEmpty else { throw ImportFileError.unrecognised }
            for entry in found {
                guard !entry.encrypted else { throw ImportFileError.encrypted }
                guard let contents = zip.contents(of: entry) else { throw ImportFileError.unrecognised }
                builder.read(csv: contents)
            }
        } else {
            builder.read(csv: file)
        }
        guard builder.recognised else { throw ImportFileError.unrecognised }
        let shows = builder.shows()
        guard !shows.isEmpty else { throw ImportFileError.empty }
        return shows
    }

    /// The shows, built up row by row from whichever of the three CSV shapes a file is.
    private struct Builder {
        private struct Show {
            var tvdbId: Int?
            var title = ""
            var seasons: [Int: Set<Int>] = [:]
            var followed = false, forLater = false, archived = false
            var lastWatchedAt: Int64?
        }

        private var byKey: [String: Show] = [:]
        private(set) var recognised = false

        private static func key(_ tvdbId: Int?, _ title: String) -> String? {
            if let tvdbId { return "id:\(tvdbId)" }
            let name = title.trimmingCharacters(in: .whitespaces).lowercased()
            return name.isEmpty ? nil : "name:\(name)"
        }

        private mutating func update(_ tvdbId: Int?, _ title: String, _ change: (inout Show) -> Void) {
            guard let key = Self.key(tvdbId, title) else { return }
            var show = byKey[key] ?? Show(tvdbId: tvdbId)
            if show.title.isEmpty { show.title = title }
            change(&show)
            byKey[key] = show
        }

        mutating func read(csv: Data) {
            CSVRows.forEach(in: csv) { row in
                if let key = row["key"] {
                    // The GDPR zip's event log.
                    recognised = true
                    let id = Int(row["s_id"] ?? ""), title = row["series_name"] ?? ""
                    if key.hasPrefix("watch-episode-") || key.hasPrefix("rewatch-episode-") {
                        // Newer rows number the episode in `s_no` / `ep_no`; older ones in
                        // `season_number` / `episode_number`.
                        let positional = (Int(row["ep_no"] ?? "") ?? 0) > 0
                        let season = Int((positional ? row["s_no"] : (row["season_number"] ?? row["s_no"])) ?? "")
                        let episode = Int((positional ? row["ep_no"] : row["episode_number"]) ?? "")
                        guard let season, let episode, episode > 0, season >= 0 else { return }
                        let at = Self.date(row["created_at"])
                        update(id, title) { show in
                            show.seasons[season, default: []].insert(episode)
                            if let at, at > (show.lastWatchedAt ?? 0) { show.lastWatchedAt = at }
                        }
                    } else if key.hasPrefix("user-series-") {
                        update(id, title) { show in
                            show.followed = show.followed || row["is_followed"] == "true"
                            show.forLater = show.forLater || row["is_for_later"] == "true"
                            show.archived = show.archived || row["is_archived"] == "true"
                        }
                    }
                } else if row["series_tvdb_id"] != nil || row["is_watched"] != nil {
                    // "Export my data": one row per episode, watched or not.
                    recognised = true
                    guard row["is_watched"] == "true", let season = Int(row["season"] ?? ""),
                          let episode = Int(row["episode"] ?? ""), episode > 0, season >= 0 else { return }
                    let at = Self.date(row["watched_at"])
                    update(Int(row["series_tvdb_id"] ?? ""), row["title"] ?? "") { show in
                        show.seasons[season, default: []].insert(episode)
                        show.followed = true
                        if let at, at > (show.lastWatchedAt ?? 0) { show.lastWatchedAt = at }
                    }
                } else if row["tvdb_id"] != nil, row["status"] != nil {
                    // "Export my data": the series list, with where each stands.
                    recognised = true
                    let status = row["status"] ?? ""
                    update(Int(row["tvdb_id"] ?? ""), row["title"] ?? "") { show in
                        show.followed = true
                        if status == "not_started_yet" { show.forLater = true }
                        if status == "stopped" || status == "archived" { show.archived = true }
                    }
                }
            }
        }

        func shows() -> [ImportTvShow] {
            byKey.values
                .filter { !$0.seasons.isEmpty || $0.followed || $0.forLater }
                .map { show in
                    ImportTvShow(tvdbId: show.tvdbId, title: show.title,
                                 seasons: show.seasons.keys.sorted().map { .init(number: $0, watched: show.seasons[$0]!.sorted()) },
                                 followed: show.followed, forLater: show.forLater, archived: show.archived,
                                 lastWatchedAt: show.lastWatchedAt)
                }
                .sorted { ($0.title, $0.tvdbId ?? 0) < ($1.title, $1.tvdbId ?? 0) }
        }

        /// "2024-11-02 11:53:58" (UTC) or an ISO-8601 instant, as ms epoch.
        private static func date(_ raw: String?) -> Int64? {
            guard let raw, raw.count >= 19 else { return nil }
            // ISO exports can include a real timezone offset. Do not drop it and pretend UTC.
            if raw.contains("T") {
                let formatter = ISO8601DateFormatter()
                if let instant = formatter.date(from: raw) { return Int64(instant.timeIntervalSince1970 * 1000) }
                formatter.formatOptions.insert(.withFractionalSeconds)
                if let instant = formatter.date(from: raw) { return Int64(instant.timeIntervalSince1970 * 1000) }
            }
            let head = String(raw.prefix(19)).replacingOccurrences(of: "T", with: " ")
            let parts = head.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
            guard parts.count == 6 else { return nil }
            var c = DateComponents()
            (c.year, c.month, c.day, c.hour, c.minute, c.second) = (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let date = calendar.date(from: c), parts[0] > 2000 else { return nil }
            return Int64(date.timeIntervalSince1970 * 1000)
        }
    }
}

// MARK: - Regression

#if DEBUG
/// `-verifyImport 1`: the readers against the real shapes (headers and rows copied from real
/// exports' public fixtures), with no network and no file on disk.
enum ImportRegression {
    static func run() {
        var passed = 0
        func check(_ ok: Bool, _ name: String) {
            precondition(ok, "Import regression: \(name)")
            passed += 1
        }

        // CSV: quotes, a comma and a newline inside a field, a doubled quote, CRLF, a BOM.
        var rows: [[String: String]] = []
        CSVRows.forEach(in: Data("\u{FEFF}a,b,c\r\n1,\"x, y\",3\r\n4,\"say \"\"hi\"\"\nthere\",\r\n".utf8)) { rows.append($0) }
        check(rows.count == 2 && rows[0] == ["a": "1", "b": "x, y", "c": "3"], "csv: a quoted comma stays in its field")
        check(rows[1]["b"] == "say \"hi\"\nthere" && rows[1]["c"] == nil, "csv: doubled quotes, a newline in quotes, an empty field")

        // TV Time, the GDPR zip's event log (real header).
        let v2 = """
        created_at,user_id,key,total_series_runtime,updated_at,total_movies_runtime,movie_watch_count,ep_watch_count,series_follow_count,uuid,is_archived,is_followed,s_id,is_for_later,most_recent_ep_watched,followed_at,runtime,bulk_type,s_no,ep_no,is_unitary,ep_id,rewatch_count,gsi,is_special,movie_name,series_name,season_number,episode_number
        2021-11-12 17:11:33,0,tracking-stats,13800540,2026-06-04 14:04:56,0,0,4868,200,,,,,,,,,,,,,,,,,,,,
        2024-11-02 11:53:58,0,watch-episode-a,,2024-11-02 11:53:58,,,,,,,,413526,,,,2520,season,1,5,false,9476788,,,,,Treason,1,5
        2024-11-01 10:00:00,0,watch-episode-b,,2024-11-01 10:00:00,,,,,,,,413526,,,,2520,season,1,4,false,9476787,,,,,Treason,1,4
        2016-08-10 16:48:22,0,rewatch-episode-c,,2016-08-10 16:48:22,,,,,,,,75707,,,,,,1,4,false,306587,0,,,,"Unit, The",1,4
        2020-01-01 00:00:00,0,user-series-d,,2020-01-01 00:00:00,,,,,,true,true,75707,false,,,,,,,,,,,,,"Unit, The",,
        2020-01-01 00:00:00,0,user-series-e,,2020-01-01 00:00:00,,,,,,false,false,121361,true,,,,,,,,,,,,,Game of Thrones,,
        """
        let gdpr = (try? TvTimeExport.parse(Data(v2.utf8), fileName: "tracking-prod-records-v2.csv")) ?? []
        let treason = gdpr.first { $0.tvdbId == 413526 }
        check(gdpr.count == 3, "tv time: one show per TheTVDB id, the stats row ignored")
        check(treason?.seasons == [.init(number: 1, watched: [4, 5])] && treason?.title == "Treason",
              "tv time: episodes gather under their season")
        check(treason?.lastWatchedAt == 1_730_548_438_000, "tv time: the newest watch is the show's last, in UTC")
        let unit = gdpr.first { $0.tvdbId == 75707 }
        check(unit?.archived == true && unit?.followed == true && unit?.title == "Unit, The" && unit?.seasons.first?.watched == [4],
              "tv time: a rewatch is a watch; the show's flags come from its user-series row")
        check(gdpr.first { $0.tvdbId == 121361 }?.forLater == true, "tv time: a show saved for later with nothing watched is kept")

        // TV Time, "export my data".
        let episodes = """
        series_tvdb_id,series_imdb_id,series_uuid,title,season,episode,tvdb_id,is_watched,watched_at,rewatch_count,special
        346328,,u0,Elite,1,1,6671792,true,2019-10-04 03:43:42,0,false
        346328,,u1,Elite,6,1,9367539,false,,0,false
        """
        let newer = (try? TvTimeExport.parse(Data(episodes.utf8), fileName: "tvtime-series-episodes.csv")) ?? []
        check(newer.count == 1 && newer[0].seasons == [.init(number: 1, watched: [1])],
              "tv time: only watched episodes of the newer export count")
        let series = "uuid,tvdb_id,imdb_id,title,status,created_at\nu,281485,,Marvel's Agent Carter,not_started_yet,2018-09-08T10:16:19Z\n"
        let listed = (try? TvTimeExport.parse(Data(series.utf8), fileName: "tvtime-series.csv")) ?? []
        check(listed.first?.forLater == true && listed.first?.seasons.isEmpty == true, "tv time: a not-started series is saved for later")

        // Not an export at all.
        var thrown: ImportFileError?
        do { _ = try TvTimeExport.parse(Data("hello,world\n1,2\n".utf8), fileName: "x.csv") } catch { thrown = error as? ImportFileError }
        check(thrown == .unrecognised, "tv time: another CSV is not an export")

        // MyAnimeList.
        let mal = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <myanimelist><myinfo><user_name>x</user_name></myinfo>
        <anime><series_animedb_id>16498</series_animedb_id><series_title><![CDATA[Shingeki no Kyojin]]></series_title>
        <my_watched_episodes>25</my_watched_episodes><my_status>Completed</my_status><my_times_watched>1</my_times_watched></anime>
        <anime><series_animedb_id>5114</series_animedb_id><series_title><![CDATA[Fullmetal Alchemist: Brotherhood]]></series_title>
        <my_watched_episodes>0</my_watched_episodes><my_status>Plan to Watch</my_status></anime>
        </myanimelist>
        """
        let list = (try? MalExport.parse(Data(mal.utf8))) ?? []
        check(list == [ImportMalRow(malId: 16498, status: "Completed", watched: 25, title: "Shingeki no Kyojin"),
                       ImportMalRow(malId: 5114, status: "Plan to Watch", watched: 0, title: "Fullmetal Alchemist: Brotherhood")],
              "mal: each <anime> is a row with its id, status and count")
        thrown = nil
        do { _ = try MalExport.parse(Data("<html><body>nope</body></html>".utf8)) } catch { thrown = error as? ImportFileError }
        check(thrown == .unrecognised, "mal: some other XML is not an export")

        // gzip and zip, round-tripped through the system's own deflate.
        let payload = Data(mal.utf8)
        if let deflated = try? (payload as NSData).compressed(using: .zlib) as Data {
            var gz = Data([0x1f, 0x8b, 8, 0x08, 0, 0, 0, 0, 0, 3]) + Data("animelist.xml".utf8) + Data([0])
            func le(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) }) }
            gz += deflated + le(ImportInflate.checksum(payload)) + le(UInt32(payload.count))
            check(Gzip.inflate(gz) == payload, "gzip: the header's file name is skipped and the stream inflated")
            check(((try? MalExport.parse(gz)) ?? []).count == 2, "mal: the .xml.gz it is downloaded as reads the same")

            let csv = Data(v2.utf8)
            if let body = try? (csv as NSData).compressed(using: .zlib) as Data {
                let zip = Self.zip(name: "export/tracking-prod-records-v2.csv", body: body, size: csv.count, method: 8)
                check(ZipReader(zip)?.entry(named: "tracking-prod-records-v2.csv") != nil, "zip: an entry is found by its file name, in a folder")
                check(((try? TvTimeExport.parse(zip, fileName: "export.zip")) ?? []).count == 3, "tv time: the zip reads as its CSV does")
                var locked: ImportFileError?
                do { _ = try TvTimeExport.parse(Self.zip(name: "tracking-prod-records-v2.csv", body: body, size: csv.count, method: 8, flags: 1),
                                                fileName: "export.zip") } catch { locked = error as? ImportFileError }
                check(locked == .encrypted, "zip: a password-protected export says so")
            }
        }
        // Python gzip fixture, independent of Foundation's compressor (including FEXTRA >255).
        let extraGzip = Data(base64Encoded: "H4sIBAAAAAAC/wABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGWOTQqCMQxEr+INii5chSz0IKU1AwZaW0zko7dX6y98u5k3bzFUR7poRVFzphmZDFeFxdkkRxXeUljDj+fqBXxsS25jc0Bu/Wu/Jqojmie/2cOqvcAhFH7wuS/JT2dIRFdrAuPdfiorTuH9MvxfvwPeKxMYyAAAAA==")!
        check((try? MalExport.parse(extraGzip).first?.malId) == 1, "gzip: independent FEXTRA export")
        var broken = extraGzip
        broken[broken.count - 8] ^= 1
        check(Gzip.inflate(broken) == nil, "gzip: a corrupt checksum is rejected")
        check(Gzip.inflate(Data(extraGzip.dropLast(4))) == nil, "gzip: a truncated trailer is rejected")
        thrown = nil
        do { _ = try MalExport.parse(Data(mal.dropLast(8).utf8)) } catch { thrown = error as? ImportFileError }
        check(thrown == .unrecognised, "mal: malformed XML cannot silently import only a prefix")
        var damagedZip = Self.zip(name: "tracking-prod-records-v2.csv", body: Data(v2.utf8), size: v2.utf8.count, method: 0)
        damagedZip[30 + "tracking-prod-records-v2.csv".utf8.count] ^= 1
        check(ZipReader(damagedZip).flatMap { zip in zip.entry(named: "tracking-prod-records-v2.csv").flatMap { zip.contents(of: $0) } } == nil,
              "zip: corrupt stored data is rejected")
        check(ZipReader(Data(damagedZip.dropLast(4))) == nil, "zip: a truncated directory is rejected")
        let offsetEpisodes = episodes.replacingOccurrences(of: "2019-10-04 03:43:42", with: "2019-10-04T09:13:42+05:30")
        let offsetList = try? TvTimeExport.parse(Data(offsetEpisodes.utf8), fileName: "tvtime-series-episodes.csv")
        check(offsetList?.first?.lastWatchedAt == newer.first?.lastWatchedAt, "tv time: timezone offsets preserve the same instant")
        print("IMPORT_REGRESSIONS_PASS \(passed)")
    }

    /// A one-entry zip (local header, central directory, end record) around an already-deflated body.
    private static func zip(name: String, body: Data, size: Int, method: UInt16, flags: UInt16 = 0) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        let nameBytes = [UInt8](name.utf8)
        let plain = method == 8 ? ImportInflate.decode(body, gzip: false) : body
        let crc = Int(ImportInflate.checksum(plain ?? Data()))
        var out = Data()
        out += [0x50, 0x4b, 0x03, 0x04] + le16(20) + le16(Int(flags)) + le16(Int(method)) + le16(0) + le16(0)
        out += le32(crc) + le32(body.count) + le32(size) + le16(nameBytes.count) + le16(0)
        out += nameBytes
        out += body
        let central = out.count
        out += [0x50, 0x4b, 0x01, 0x02] + le16(20) + le16(20) + le16(Int(flags)) + le16(Int(method)) + le16(0) + le16(0)
        out += le32(crc) + le32(body.count) + le32(size) + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0)
        out += le32(0) + le32(0)
        out += nameBytes
        let centralSize = out.count - central
        out += [0x50, 0x4b, 0x05, 0x06] + le16(0) + le16(0) + le16(1) + le16(1) + le32(centralSize) + le32(central) + le16(0)
        return out
    }
}
#endif
