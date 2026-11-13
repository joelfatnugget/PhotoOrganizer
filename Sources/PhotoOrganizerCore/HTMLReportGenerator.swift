import Foundation

/// Generates a self-contained interactive HTML map and analytics dashboard (`index.html`)
/// inside the organized destination folder using relative file links.
public struct HTMLReportGenerator: Sendable {
    public static let filename = "index.html"

    public init() {}

    private struct ReportPayload: Encodable {
        struct KPI: Encodable {
            let totalMedia: Int
            let peopleCount: Int
            let venueCount: Int
            let receiptCount: Int
            let receiptTotalFormatted: String
            let blurryCount: Int
            let burstExtraCount: Int
            let geotaggedCount: Int
        }

        struct PersonEntry: Encodable {
            let id: String
            let label: String
            let photoCount: Int
            let thumbnailDataURL: String?
        }

        struct ReceiptEntry: Encodable {
            let itemID: String
            let filename: String
            let relativePath: String
            let dateISO: String
            let merchant: String
            let amount: Double?
            let currency: String
            let location: String
            let diningSession: String?
        }

        struct ItemEntry: Encodable {
            let id: String
            let filename: String
            let relativePath: String
            let encodedRelativePath: String
            let mediaType: String
            let dateDisplay: String
            let dateTimestamp: Double
            let category: String
            let categoryFolder: String
            let categoryColor: String
            let categories: [String]
            let locationDisplay: String
            let venueName: String?
            let venueCategory: String?
            let latitude: Double?
            let longitude: Double?
            let plotLatitude: Double?
            let plotLongitude: Double?
            let cameraModel: String?
            let sharpnessScore: Double
            let isBlurry: Bool
            let hasClosedEyes: Bool
            let isBurstBestShot: Bool
            let isBurstExtra: Bool
            let isDuplicate: Bool
            let peopleIDs: [String]
            let peopleNames: [String]
            let diningSession: String?
            let merchant: String?
            let receiptAmount: Double?
            let receiptCurrency: String?
        }

        let title: String
        let generatedAt: String
        let sourceFolder: String
        let destinationFolder: String
        let kpi: KPI
        let people: [PersonEntry]
        let receipts: [ReceiptEntry]
        let items: [ItemEntry]
    }

    @discardableResult
    public func generate(plan: OrganizationPlan) throws -> URL {
        let html = try renderHTML(plan: plan)
        let outputURL = plan.destinationRootURL.appendingPathComponent(Self.filename)
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    public func renderHTML(plan: OrganizationPlan) throws -> String {
        let payload = buildPayload(plan: plan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(payload)
        var jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        // Prevent </script> inside filenames or OCR strings from closing the inline script tag.
        jsonString = jsonString.replacingOccurrences(of: "</", with: "<\\/")

        return Self.htmlTemplate
            .replacingOccurrences(of: "__REPORT_TITLE__", with: escapeHTML(payload.title))
            .replacingOccurrences(of: "__PAYLOAD_JSON__", with: jsonString)
    }

    private func buildPayload(plan: OrganizationPlan) -> ReportPayload {
        let primaryOpByItemID = Dictionary(
            plan.operations.filter { !$0.isSecondaryCrossLink }.map { ($0.itemID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let clusterByID = Dictionary(uniqueKeysWithValues: plan.faceClusters.map { ($0.id, $0) })
        let sessionByID = Dictionary(uniqueKeysWithValues: plan.diningSessions.map { ($0.id, $0) })

        let displayFormatter = DateFormatter()
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")
        displayFormatter.timeZone = plan.options.timeZone
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let isoFormatter = ISO8601DateFormatter()

        // Track identical coordinate buckets so pins can be spiral-offset cleanly on the map.
        var coordCounts: [String: Int] = [:]
        var itemEntries: [ReportPayload.ItemEntry] = []
        var receiptEntries: [ReportPayload.ReceiptEntry] = []
        var venueSet: Set<String> = []
        var blurryCount = 0
        var burstExtraCount = 0
        var geotaggedCount = 0
        var receiptAmountByCurrency: [String: Double] = [:]
        var receiptCount = 0

        for item in plan.items {
            if item.isBlurry { blurryCount += 1 }
            if item.isBurstExtra { burstExtraCount += 1 }
            if item.isReceipt { receiptCount += 1 }

            let op = primaryOpByItemID[item.id]
            let relativePath = op?.destinationRelativePath ?? item.sourceURL.lastPathComponent
            let encodedRel = percentEncodeRelativePath(relativePath)

            let locDisplay = item.resolvedLocation?.displayVenueOrSublocality ?? "Unknown Location"
            if let venue = item.resolvedLocation?.venueName, !venue.isEmpty {
                venueSet.insert(venue)
            } else if let loc = item.resolvedLocation {
                venueSet.insert(loc.folderName)
            }

            let gps = item.effectiveGPS
            var plotLat: Double?
            var plotLon: Double?
            if let coord = gps {
                geotaggedCount += 1
                let key = String(format: "%.5f,%.5f", coord.latitude, coord.longitude)
                let idx = coordCounts[key, default: 0]
                coordCounts[key] = idx + 1
                if idx == 0 {
                    plotLat = coord.latitude
                    plotLon = coord.longitude
                } else {
                    // Deterministic golden-angle spiral (~18m step) separates co-located shots cleanly.
                    let angle = Double(idx) * 2.39996323
                    let radiusDeg = 0.00016 * sqrt(Double(idx))
                    plotLat = coord.latitude + radiusDeg * sin(angle)
                    plotLon = coord.longitude + radiusDeg * cos(angle)
                }
            }

            let peopleIDs = item.assignedFaceClusterIDs.map(String.init)
            let peopleNames = item.assignedFaceClusterIDs.compactMap { clusterByID[$0]?.displayName }
            let diningSessionName = item.assignedDiningSessionID.flatMap { sessionByID[$0]?.folderName }

            if let meta = item.receiptMetadata, item.isReceipt {
                let currency = meta.currencySymbol ?? "$"
                if let amount = meta.totalAmount {
                    receiptAmountByCurrency[currency, default: 0] += amount
                }
                receiptEntries.append(
                    ReportPayload.ReceiptEntry(
                        itemID: item.id.uuidString,
                        filename: item.sourceURL.lastPathComponent,
                        relativePath: encodedRel,
                        dateISO: displayFormatter.string(from: item.captureDate),
                        merchant: meta.merchantName ?? "Unknown Merchant",
                        amount: meta.totalAmount,
                        currency: currency,
                        location: locDisplay,
                        diningSession: diningSessionName
                    )
                )
            } else if item.isReceipt {
                receiptEntries.append(
                    ReportPayload.ReceiptEntry(
                        itemID: item.id.uuidString,
                        filename: item.sourceURL.lastPathComponent,
                        relativePath: encodedRel,
                        dateISO: displayFormatter.string(from: item.captureDate),
                        merchant: "Receipt",
                        amount: nil,
                        currency: "$",
                        location: locDisplay,
                        diningSession: diningSessionName
                    )
                )
            }

            let mediaTypeLabel: String
            switch item.mediaKind {
            case .video:
                mediaTypeLabel = "video"
            case .photo, .livePhotoPair:
                mediaTypeLabel = "photo"
            }

            itemEntries.append(
                ReportPayload.ItemEntry(
                    id: item.id.uuidString,
                    filename: item.sourceURL.lastPathComponent,
                    relativePath: relativePath,
                    encodedRelativePath: encodedRel,
                    mediaType: mediaTypeLabel,
                    dateDisplay: displayFormatter.string(from: item.captureDate),
                    dateTimestamp: item.captureDate.timeIntervalSince1970,
                    category: item.primaryCategory.rawValue,
                    categoryFolder: item.primaryCategory.folderName,
                    categoryColor: Self.colorHex(for: item.primaryCategory),
                    categories: item.detectedCategories.map(\.folderName).sorted(),
                    locationDisplay: locDisplay,
                    venueName: item.resolvedLocation?.venueName,
                    venueCategory: item.resolvedLocation?.venueCategory,
                    latitude: gps?.latitude,
                    longitude: gps?.longitude,
                    plotLatitude: plotLat,
                    plotLongitude: plotLon,
                    cameraModel: item.cameraModel,
                    sharpnessScore: item.sharpnessScore,
                    isBlurry: item.isBlurry,
                    hasClosedEyes: item.hasClosedEyes,
                    isBurstBestShot: item.isBurstBestShot,
                    isBurstExtra: item.isBurstExtra,
                    isDuplicate: item.isDuplicate,
                    peopleIDs: peopleIDs,
                    peopleNames: peopleNames,
                    diningSession: diningSessionName,
                    merchant: item.receiptMetadata?.merchantName,
                    receiptAmount: item.receiptMetadata?.totalAmount,
                    receiptCurrency: item.receiptMetadata?.currencySymbol
                )
            )
        }

        let peopleEntries: [ReportPayload.PersonEntry] = plan.faceClusters.map { cluster in
            let dataURL = cluster.sampleThumbnailJPEG.map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
            return ReportPayload.PersonEntry(
                id: String(cluster.id),
                label: cluster.displayName,
                photoCount: cluster.photoIDs.count,
                thumbnailDataURL: dataURL
            )
        }

        let receiptTotalFormatted: String
        if receiptAmountByCurrency.isEmpty {
            receiptTotalFormatted = "\(receiptCount) receipts"
        } else {
            receiptTotalFormatted = receiptAmountByCurrency
                .sorted { $0.value > $1.value }
                .map { String(format: "%@%.2f", $0.key, $0.value) }
                .joined(separator: " + ")
        }

        return ReportPayload(
            title: "\(plan.destinationRootURL.lastPathComponent) — Photo Archive",
            generatedAt: isoFormatter.string(from: Date()),
            sourceFolder: plan.sourceRootURL.path,
            destinationFolder: plan.destinationRootURL.path,
            kpi: ReportPayload.KPI(
                totalMedia: plan.items.count,
                peopleCount: plan.faceClusters.count,
                venueCount: venueSet.count,
                receiptCount: receiptCount,
                receiptTotalFormatted: receiptTotalFormatted,
                blurryCount: blurryCount,
                burstExtraCount: burstExtraCount,
                geotaggedCount: geotaggedCount
            ),
            people: peopleEntries,
            receipts: receiptEntries,
            items: itemEntries
        )
    }

    private func percentEncodeRelativePath(_ relativePath: String) -> String {
        relativePath
            .split(separator: "/")
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func colorHex(for category: PhotoCategory) -> String {
        switch category {
        case .people: return "#2563eb"
        case .foodAndRestaurants: return "#ea580c"
        case .receipts: return "#059669"
        case .pets: return "#7c3aed"
        case .screenshots: return "#475569"
        case .sceneryAndGeneral: return "#0d9488"
        }
    }

    private static let htmlTemplate = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <title>__REPORT_TITLE__</title>
      <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" crossorigin="" />
      <style>
        :root {
          --bg: #f6f7f9;
          --surface: #ffffff;
          --surface-muted: #eef1f5;
          --border: #dfe4ec;
          --text: #111827;
          --text-muted: #5b6472;
          --accent: #2563eb;
          --radius: 12px;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #0f131a;
            --surface: #171d27;
            --surface-muted: #202836;
            --border: #2c3647;
            --text: #f3f4f6;
            --text-muted: #9ca3af;
            --accent: #60a5fa;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
          background: var(--bg);
          color: var(--text);
          line-height: 1.45;
        }
        header {
          padding: 20px 24px 12px;
          border-bottom: 1px solid var(--border);
          background: var(--surface);
        }
        header h1 {
          margin: 0;
          font-size: 20px;
          font-weight: 700;
        }
        header .sub {
          margin-top: 4px;
          font-size: 12px;
          color: var(--text-muted);
          display: flex;
          flex-wrap: wrap;
          gap: 16px;
        }
        main {
          max-width: 1440px;
          margin: 0 auto;
          padding: 18px 24px 48px;
          display: flex;
          flex-direction: column;
          gap: 18px;
        }
        .kpi-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(175px, 1fr));
          gap: 12px;
        }
        .kpi-card {
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 14px 16px;
        }
        .kpi-label {
          font-size: 11px;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: var(--text-muted);
        }
        .kpi-value {
          font-size: 22px;
          font-weight: 700;
          margin-top: 4px;
        }
        .panel {
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          overflow: hidden;
        }
        .panel-header {
          padding: 12px 16px;
          border-bottom: 1px solid var(--border);
          display: flex;
          justify-content: space-between;
          align-items: center;
          gap: 12px;
          flex-wrap: wrap;
        }
        .panel-title {
          font-size: 14px;
          font-weight: 600;
        }
        #map {
          width: 100%;
          height: 380px;
          background: var(--surface-muted);
        }
        .controls {
          padding: 14px 16px;
          display: flex;
          flex-direction: column;
          gap: 12px;
        }
        .filter-row {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          align-items: center;
        }
        input[type="search"], select {
          padding: 8px 12px;
          border-radius: 8px;
          border: 1px solid var(--border);
          background: var(--surface-muted);
          color: var(--text);
          font-size: 13px;
        }
        input[type="search"] {
          min-width: 240px;
          flex: 1;
        }
        .pill {
          border: 1px solid var(--border);
          background: var(--surface-muted);
          color: var(--text);
          border-radius: 999px;
          padding: 5px 12px;
          font-size: 12px;
          font-weight: 500;
          cursor: pointer;
          display: inline-flex;
          align-items: center;
          gap: 6px;
        }
        .pill.active {
          background: var(--accent);
          border-color: var(--accent);
          color: #ffffff;
        }
        .dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          display: inline-block;
        }
        .people-strip {
          display: flex;
          gap: 10px;
          overflow-x: auto;
          padding-bottom: 4px;
        }
        .person-chip {
          border: 1px solid var(--border);
          background: var(--surface-muted);
          border-radius: 10px;
          padding: 6px 10px;
          display: flex;
          align-items: center;
          gap: 8px;
          cursor: pointer;
          white-space: nowrap;
          color: var(--text);
          font-size: 12px;
        }
        .person-chip.active {
          border-color: var(--accent);
          box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent);
        }
        .person-chip img {
          width: 28px;
          height: 28px;
          border-radius: 50%;
          object-fit: cover;
          background: var(--border);
        }
        .gallery {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
          gap: 14px;
          padding: 16px;
        }
        .photo-card {
          border: 1px solid var(--border);
          border-radius: 10px;
          overflow: hidden;
          background: var(--surface);
          cursor: pointer;
          transition: transform 0.12s ease;
          display: flex;
          flex-direction: column;
        }
        .photo-card:hover {
          transform: translateY(-2px);
        }
        .thumb-wrap {
          width: 100%;
          aspect-ratio: 4 / 3;
          background: var(--surface-muted);
          position: relative;
          overflow: hidden;
          display: flex;
          align-items: center;
          justify-content: center;
        }
        .thumb-wrap img {
          width: 100%;
          height: 100%;
          object-fit: cover;
          display: block;
        }
        .thumb-fallback {
          font-size: 11px;
          color: var(--text-muted);
          padding: 8px;
          text-align: center;
        }
        .badge-row {
          position: absolute;
          top: 8px;
          left: 8px;
          right: 8px;
          display: flex;
          justify-content: space-between;
          gap: 4px;
          pointer-events: none;
        }
        .badge {
          font-size: 10px;
          font-weight: 600;
          padding: 2px 7px;
          border-radius: 6px;
          background: rgba(17, 24, 39, 0.78);
          color: #ffffff;
        }
        .badge.warn { background: #b91c1c; }
        .badge.good { background: #047857; }
        .card-body {
          padding: 10px 12px;
          font-size: 12px;
        }
        .card-title {
          font-weight: 600;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .card-meta {
          color: var(--text-muted);
          font-size: 11px;
          margin-top: 3px;
        }
        table {
          width: 100%;
          border-collapse: collapse;
          font-size: 13px;
        }
        th, td {
          text-align: left;
          padding: 10px 14px;
          border-bottom: 1px solid var(--border);
        }
        th {
          font-size: 11px;
          text-transform: uppercase;
          color: var(--text-muted);
          background: var(--surface-muted);
        }
        .modal-backdrop {
          position: fixed;
          inset: 0;
          background: rgba(0, 0, 0, 0.78);
          display: none;
          align-items: center;
          justify-content: center;
          z-index: 9999;
          padding: 24px;
        }
        .modal-backdrop.open { display: flex; }
        .modal {
          background: var(--surface);
          border-radius: 14px;
          max-width: 1040px;
          width: 100%;
          max-height: 90vh;
          display: grid;
          grid-template-columns: 1.4fr 1fr;
          overflow: hidden;
        }
        @media (max-width: 820px) {
          .modal { grid-template-columns: 1fr; overflow-y: auto; }
        }
        .modal-media {
          background: #0b0e13;
          display: flex;
          align-items: center;
          justify-content: center;
          min-height: 320px;
          max-height: 85vh;
        }
        .modal-media img {
          max-width: 100%;
          max-height: 85vh;
          object-fit: contain;
        }
        .modal-info {
          padding: 20px;
          overflow-y: auto;
          display: flex;
          flex-direction: column;
          gap: 10px;
          font-size: 13px;
        }
        .modal-close {
          align-self: flex-end;
          border: 1px solid var(--border);
          background: var(--surface-muted);
          color: var(--text);
          border-radius: 8px;
          padding: 4px 10px;
          cursor: pointer;
        }
        .kv { display: grid; grid-template-columns: 110px 1fr; gap: 6px 10px; }
        .kv-k { color: var(--text-muted); font-size: 12px; }
        .kv-v { word-break: break-word; }
      </style>
    </head>
    <body>
      <header>
        <h1 id="reportTitle">PhotoOrganizer Archive</h1>
        <div class="sub">
          <span id="metaSource"></span>
          <span id="metaDest"></span>
          <span id="metaGenerated"></span>
        </div>
      </header>

      <main>
        <section class="kpi-grid" id="kpiGrid"></section>

        <section class="panel">
          <div class="panel-header">
            <span class="panel-title">Location & Venue Map</span>
            <span id="mapStatus" style="font-size:12px;color:var(--text-muted);"></span>
          </div>
          <div id="map"></div>
        </section>

        <section class="panel">
          <div class="controls">
            <div class="filter-row">
              <input id="searchInput" type="search" placeholder="Search filename, venue, location, person, camera, merchant..." />
              <select id="venueSelect"><option value="">All Locations & Venues</option></select>
              <button class="pill" id="resetFiltersBtn">Reset Filters</button>
            </div>
            <div class="filter-row" id="categoryPills"></div>
            <div class="filter-row" id="qualityPills"></div>
            <div class="people-strip" id="peopleStrip"></div>
          </div>
        </section>

        <section class="panel" id="receiptsPanel" style="display:none;">
          <div class="panel-header">
            <span class="panel-title">Receipts & Dining Expenses</span>
            <span id="receiptsSummary" style="font-size:12px;color:var(--text-muted);"></span>
          </div>
          <div style="overflow-x:auto;">
            <table>
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Merchant</th>
                  <th>Amount</th>
                  <th>Location / Venue</th>
                  <th>Dining Session</th>
                  <th>File</th>
                </tr>
              </thead>
              <tbody id="receiptsBody"></tbody>
            </table>
          </div>
        </section>

        <section class="panel">
          <div class="panel-header">
            <span class="panel-title">Media Gallery</span>
            <span id="galleryCount" style="font-size:12px;color:var(--text-muted);"></span>
          </div>
          <div class="gallery" id="gallery"></div>
        </section>
      </main>

      <div class="modal-backdrop" id="modalBackdrop">
        <div class="modal" role="dialog" aria-modal="true">
          <div class="modal-media" id="modalMedia"></div>
          <div class="modal-info">
            <button class="modal-close" id="modalCloseBtn">Close</button>
            <h3 id="modalTitle" style="margin:0;font-size:16px;"></h3>
            <div class="kv" id="modalDetails"></div>
            <a id="modalOpenLink" target="_blank" style="color:var(--accent);font-weight:600;margin-top:6px;">Open Organized File</a>
          </div>
        </div>
      </div>

      <script id="reportData" type="application/json">__PAYLOAD_JSON__</script>
      <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" crossorigin=""></script>
      <script>
        (function () {
          const data = JSON.parse(document.getElementById('reportData').textContent);

          document.getElementById('reportTitle').textContent = data.title;
          document.getElementById('metaSource').textContent = 'Source: ' + data.sourceFolder;
          document.getElementById('metaDest').textContent = 'Destination: ' + data.destinationFolder;
          document.getElementById('metaGenerated').textContent = 'Generated: ' + data.generatedAt;

          const state = {
            search: '',
            category: 'ALL',
            quality: 'ALL',
            personID: 'ALL',
            venue: ''
          };

          const kpis = [
            { label: 'Total Media', value: data.kpi.totalMedia },
            { label: 'People Identified', value: data.kpi.peopleCount },
            { label: 'Locations / Venues', value: data.kpi.venueCount },
            { label: 'Geotagged Pins', value: data.kpi.geotaggedCount },
            { label: 'Receipts', value: data.kpi.receiptTotalFormatted },
            { label: 'Blurry / Outtakes', value: data.kpi.blurryCount },
            { label: 'Burst Extras', value: data.kpi.burstExtraCount }
          ];
          document.getElementById('kpiGrid').innerHTML = kpis.map(k =>
            '<div class="kpi-card"><div class="kpi-label">' + escapeHTML(k.label) +
            '</div><div class="kpi-value">' + escapeHTML(String(k.value)) + '</div></div>'
          ).join('');

          const venues = Array.from(new Set(data.items.map(i => i.locationDisplay))).sort();
          const venueSelect = document.getElementById('venueSelect');
          venues.forEach(v => {
            const opt = document.createElement('option');
            opt.value = v;
            opt.textContent = v;
            venueSelect.appendChild(opt);
          });

          const categoryCounts = {};
          data.items.forEach(i => {
            categoryCounts[i.categoryFolder] = (categoryCounts[i.categoryFolder] || 0) + 1;
          });
          const categoryPills = document.getElementById('categoryPills');
          const catColors = {};
          data.items.forEach(i => { catColors[i.categoryFolder] = i.categoryColor; });

          function renderCategoryPills() {
            const entries = [['ALL', data.items.length]].concat(
              Object.keys(categoryCounts).sort().map(k => [k, categoryCounts[k]])
            );
            categoryPills.innerHTML = entries.map(([cat, count]) => {
              const active = state.category === cat ? ' active' : '';
              const dot = cat === 'ALL' ? '' : '<span class="dot" style="background:' + (catColors[cat] || '#64748b') + '"></span>';
              const label = cat === 'ALL' ? 'All Categories' : cat;
              return '<button class="pill' + active + '" data-cat="' + escapeAttr(cat) + '">' + dot + escapeHTML(label) + ' (' + count + ')</button>';
            }).join('');
            categoryPills.querySelectorAll('button').forEach(btn => {
              btn.addEventListener('click', () => {
                state.category = btn.getAttribute('data-cat');
                render();
              });
            });
          }

          const qualityModes = [
            ['ALL', 'All Shots'],
            ['SHARP_BEST', 'Sharp & Best Shots'],
            ['BLURRY', 'Blurry / Outtakes'],
            ['CLOSED_EYES', 'Closed Eyes'],
            ['BURST_EXTRA', 'Burst Extras']
          ];
          const qualityPills = document.getElementById('qualityPills');
          function renderQualityPills() {
            qualityPills.innerHTML = qualityModes.map(([key, label]) => {
              const active = state.quality === key ? ' active' : '';
              return '<button class="pill' + active + '" data-q="' + key + '">' + label + '</button>';
            }).join('');
            qualityPills.querySelectorAll('button').forEach(btn => {
              btn.addEventListener('click', () => {
                state.quality = btn.getAttribute('data-q');
                render();
              });
            });
          }

          const peopleStrip = document.getElementById('peopleStrip');
          function renderPeopleStrip() {
            if (!data.people.length) {
              peopleStrip.style.display = 'none';
              return;
            }
            peopleStrip.innerHTML = data.people.map(p => {
              const active = state.personID === p.id ? ' active' : '';
              const img = p.thumbnailDataURL ? '<img src="' + p.thumbnailDataURL + '" alt="' + escapeAttr(p.label) + '" />' : '';
              return '<button class="person-chip' + active + '" data-person="' + escapeAttr(p.id) + '">' +
                img + '<span><strong>' + escapeHTML(p.label) + '</strong> (' + p.photoCount + ')</span></button>';
            }).join('');
            peopleStrip.querySelectorAll('button').forEach(btn => {
              btn.addEventListener('click', () => {
                const pid = btn.getAttribute('data-person');
                state.personID = (state.personID === pid) ? 'ALL' : pid;
                render();
              });
            });
          }

          if (data.receipts.length > 0) {
            document.getElementById('receiptsPanel').style.display = 'block';
            document.getElementById('receiptsSummary').textContent = data.kpi.receiptTotalFormatted;
            document.getElementById('receiptsBody').innerHTML = data.receipts.map(r => {
              const amt = r.amount != null ? escapeHTML(r.currency + r.amount.toFixed(2)) : '-';
              return '<tr>' +
                '<td>' + escapeHTML(r.dateISO) + '</td>' +
                '<td>' + escapeHTML(r.merchant) + '</td>' +
                '<td>' + amt + '</td>' +
                '<td>' + escapeHTML(r.location) + '</td>' +
                '<td>' + escapeHTML(r.diningSession || '-') + '</td>' +
                '<td><a href="' + escapeAttr(r.relativePath) + '" target="_blank">' + escapeHTML(r.filename) + '</a></td>' +
                '</tr>';
            }).join('');
          }

          let map = null;
          let markerLayer = null;
          if (typeof L !== 'undefined') {
            map = L.map('map');
            L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png', {
              attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
              subdomains: 'abcd',
              maxZoom: 20
            }).addTo(map);
            markerLayer = L.layerGroup().addTo(map);
          } else {
            document.getElementById('map').innerHTML = '<div style="padding:24px;color:var(--text-muted);">Map tiles require network access to Leaflet/OpenStreetMap CDN. Gallery and metadata filters remain fully interactive offline.</div>';
          }

          function filteredItems() {
            const q = state.search.trim().toLowerCase();
            return data.items.filter(item => {
              if (state.category !== 'ALL' && item.categoryFolder !== state.category) return false;
              if (state.venue && item.locationDisplay !== state.venue) return false;
              if (state.personID !== 'ALL' && !item.peopleIDs.includes(state.personID)) return false;
              if (state.quality === 'SHARP_BEST' && (item.isBlurry || item.isBurstExtra || item.isDuplicate)) return false;
              if (state.quality === 'BLURRY' && !item.isBlurry) return false;
              if (state.quality === 'CLOSED_EYES' && !item.hasClosedEyes) return false;
              if (state.quality === 'BURST_EXTRA' && !item.isBurstExtra) return false;
              if (q) {
                const hay = [
                  item.filename,
                  item.relativePath,
                  item.locationDisplay,
                  item.venueName || '',
                  item.cameraModel || '',
                  item.merchant || '',
                  item.diningSession || '',
                  item.peopleNames.join(' '),
                  item.categories.join(' ')
                ].join(' ').toLowerCase();
                if (!hay.includes(q)) return false;
              }
              return true;
            });
          }

          function updateMap(items) {
            const pinned = items.filter(i => i.plotLatitude != null && i.plotLongitude != null);
            document.getElementById('mapStatus').textContent = pinned.length + ' pinned items shown (' + items.length + ' total matching filters)';
            if (!map || !markerLayer) return;
            markerLayer.clearLayers();
            if (!pinned.length) {
              map.setView([1.3521, 103.8198], 11);
              return;
            }
            const bounds = [];
            pinned.forEach(item => {
              const latlng = [item.plotLatitude, item.plotLongitude];
              bounds.push(latlng);
              const marker = L.circleMarker(latlng, {
                radius: 7,
                fillColor: item.categoryColor,
                color: '#ffffff',
                weight: 1.5,
                opacity: 1,
                fillOpacity: 0.9
              });
              const popupHTML =
                '<div style="min-width:190px;">' +
                '<img src="' + escapeAttr(item.encodedRelativePath) + '" style="width:100%;max-height:130px;object-fit:cover;border-radius:6px;margin-bottom:6px;" onerror="this.style.display=\\'none\\'" />' +
                '<strong>' + escapeHTML(item.filename) + '</strong><br/>' +
                '<span>' + escapeHTML(item.categoryFolder) + ' - ' + escapeHTML(item.locationDisplay) + '</span><br/>' +
                '<span style="color:#6b7280;font-size:11px;">' + escapeHTML(item.dateDisplay) + '</span>' +
                '</div>';
              marker.bindPopup(popupHTML);
              marker.on('dblclick', () => openModal(item));
              marker.addTo(markerLayer);
            });
            map.fitBounds(bounds, { padding: [30, 30], maxZoom: 16 });
          }

          function renderGallery(items) {
            document.getElementById('galleryCount').textContent = items.length + ' of ' + data.items.length + ' items';
            const gallery = document.getElementById('gallery');
            const displaySlice = items.slice(0, 600);
            gallery.innerHTML = displaySlice.map(item => {
              const badges = [];
              badges.push('<span class="badge">' + escapeHTML(item.categoryFolder) + '</span>');
              if (item.isBlurry) badges.push('<span class="badge warn">Blurry</span>');
              else if (item.isBurstBestShot) badges.push('<span class="badge good">Best Shot</span>');
              else if (item.isBurstExtra) badges.push('<span class="badge">Burst Extra</span>');

              const isVideo = item.mediaType === 'video';
              const mediaEl = isVideo
                ? '<div class="thumb-fallback">Video: ' + escapeHTML(item.filename) + '</div>'
                : '<img loading="lazy" src="' + escapeAttr(item.encodedRelativePath) + '" alt="' + escapeAttr(item.filename) + '" onerror="this.style.display=\\'none\\';this.nextElementSibling.style.display=\\'flex\\';" /><div class="thumb-fallback" style="display:none;">Preview unavailable (' + escapeHTML(item.filename) + ')</div>';

              return '<div class="photo-card" data-id="' + escapeAttr(item.id) + '">' +
                '<div class="thumb-wrap">' + mediaEl + '<div class="badge-row">' + badges.join('') + '</div></div>' +
                '<div class="card-body">' +
                '<div class="card-title">' + escapeHTML(item.filename) + '</div>' +
                '<div class="card-meta">' + escapeHTML(item.locationDisplay) + ' | ' + escapeHTML(item.dateDisplay) + '</div>' +
                '</div></div>';
            }).join('');

            const byID = {};
            displaySlice.forEach(i => { byID[i.id] = i; });
            gallery.querySelectorAll('.photo-card').forEach(card => {
              card.addEventListener('click', () => {
                const item = byID[card.getAttribute('data-id')];
                if (item) openModal(item);
              });
            });
          }

          function openModal(item) {
            const modalMedia = document.getElementById('modalMedia');
            if (item.mediaType === 'video') {
              modalMedia.innerHTML = '<video controls style="max-width:100%;max-height:80vh;" src="' + escapeAttr(item.encodedRelativePath) + '"></video>';
            } else {
              modalMedia.innerHTML = '<img src="' + escapeAttr(item.encodedRelativePath) + '" alt="' + escapeAttr(item.filename) + '" />';
            }
            document.getElementById('modalTitle').textContent = item.filename;
            document.getElementById('modalOpenLink').setAttribute('href', item.encodedRelativePath);

            const rows = [
              ['Category', item.categories.join(', ')],
              ['Location', item.locationDisplay + (item.venueCategory ? ' (' + item.venueCategory + ')' : '')],
              ['Captured', item.dateDisplay],
              ['Camera', item.cameraModel || 'Unknown'],
              ['People', item.peopleNames.length ? item.peopleNames.join(', ') : 'None detected'],
              ['Quality', 'Sharpness ' + item.sharpnessScore.toFixed(3) + (item.isBlurry ? ' (Blurry)' : '') + (item.hasClosedEyes ? ' (Closed Eyes)' : '')],
              ['Burst', item.isBurstBestShot ? 'Best Shot' : (item.isBurstExtra ? 'Burst Extra' : 'Single')],
              ['Dining', item.diningSession || '-'],
              ['Receipt', item.merchant ? (item.merchant + (item.receiptAmount != null ? ' (' + (item.receiptCurrency || '$') + item.receiptAmount.toFixed(2) + ')' : '')) : '-'],
              ['Path', item.relativePath]
            ];
            document.getElementById('modalDetails').innerHTML = rows.map(([k, v]) =>
              '<div class="kv-k">' + escapeHTML(k) + '</div><div class="kv-v">' + escapeHTML(String(v)) + '</div>'
            ).join('');
            document.getElementById('modalBackdrop').classList.add('open');
          }

          document.getElementById('modalCloseBtn').addEventListener('click', () => {
            document.getElementById('modalBackdrop').classList.remove('open');
          });
          document.getElementById('modalBackdrop').addEventListener('click', (e) => {
            if (e.target.id === 'modalBackdrop') {
              document.getElementById('modalBackdrop').classList.remove('open');
            }
          });

          document.getElementById('searchInput').addEventListener('input', (e) => {
            state.search = e.target.value;
            render();
          });
          venueSelect.addEventListener('change', (e) => {
            state.venue = e.target.value;
            render();
          });
          document.getElementById('resetFiltersBtn').addEventListener('click', () => {
            state.search = '';
            state.category = 'ALL';
            state.quality = 'ALL';
            state.personID = 'ALL';
            state.venue = '';
            document.getElementById('searchInput').value = '';
            venueSelect.value = '';
            render();
          });

          function render() {
            renderCategoryPills();
            renderQualityPills();
            renderPeopleStrip();
            const items = filteredItems();
            updateMap(items);
            renderGallery(items);
          }

          function escapeHTML(str) {
            return String(str)
              .replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;');
          }
          function escapeAttr(str) {
            return escapeHTML(str).replace(/'/g, '&#39;');
          }

          render();
        })();
      </script>
    </body>
    </html>
    """
}
