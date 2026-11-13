import Foundation

/// A single spatial point in the offline GeoNames index.
public struct GeoEntry: Equatable, Hashable, Codable, Sendable {
    public let name: String
    public let parentCity: String?
    public let country: String
    public let latitude: Double
    public let longitude: Double
    public let isSublocality: Bool

    public init(
        name: String,
        parentCity: String? = nil,
        country: String,
        latitude: Double,
        longitude: Double,
        isSublocality: Bool = false
    ) {
        self.name = name
        self.parentCity = parentCity
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.isSublocality = isSublocality
    }

    public var coordinate: GPSCoordinate {
        GPSCoordinate(latitude: latitude, longitude: longitude)
    }

    public var resolvedCityName: String {
        parentCity ?? name
    }
}

/// Offline landmark, campus, or dining venue point-of-interest entry.
public struct GeoVenueEntry: Equatable, Hashable, Codable, Sendable {
    public let venueName: String
    public let category: String
    public let city: String
    public let country: String
    public let sublocality: String?
    public let latitude: Double
    public let longitude: Double
    public let aliases: [String]

    public init(
        venueName: String,
        category: String,
        city: String,
        country: String,
        sublocality: String? = nil,
        latitude: Double,
        longitude: Double,
        aliases: [String] = []
    ) {
        self.venueName = venueName
        self.category = category
        self.city = city
        self.country = country
        self.sublocality = sublocality
        self.latitude = latitude
        self.longitude = longitude
        self.aliases = aliases
    }

    public var coordinate: GPSCoordinate {
        GPSCoordinate(latitude: latitude, longitude: longitude)
    }
}

/// Fast 2D spatial K-D tree for sub-millisecond offline reverse geocoding.
public final class KDTree2D: Sendable {
    private final class Node: Sendable {
        let entry: GeoEntry
        let axis: Int
        let left: Node?
        let right: Node?

        init(entry: GeoEntry, axis: Int, left: Node?, right: Node?) {
            self.entry = entry
            self.axis = axis
            self.left = left
            self.right = right
        }
    }

    private let root: Node?

    public init(entries: [GeoEntry]) {
        self.root = Self.build(entries: entries, depth: 0)
    }

    private static func build(entries: [GeoEntry], depth: Int) -> Node? {
        guard !entries.isEmpty else { return nil }
        let axis = depth % 2
        let sorted = entries.sorted { a, b in
            axis == 0 ? a.latitude < b.latitude : a.longitude < b.longitude
        }
        let mid = sorted.count / 2
        return Node(
            entry: sorted[mid],
            axis: axis,
            left: build(entries: Array(sorted[..<mid]), depth: depth + 1),
            right: build(entries: Array(sorted[(mid + 1)...]), depth: depth + 1)
        )
    }

    /// Returns the nearest entry and its Haversine distance in meters.
    public func nearest(to target: GPSCoordinate, filter: ((GeoEntry) -> Bool)? = nil) -> (entry: GeoEntry, distanceMeters: Double)? {
        var bestEntry: GeoEntry?
        var bestDistance = Double.infinity
        search(node: root, target: target, filter: filter, bestEntry: &bestEntry, bestDistance: &bestDistance)
        guard let bestEntry else { return nil }
        return (bestEntry, bestDistance)
    }

    private func search(
        node: Node?,
        target: GPSCoordinate,
        filter: ((GeoEntry) -> Bool)?,
        bestEntry: inout GeoEntry?,
        bestDistance: inout Double
    ) {
        guard let node else { return }

        if filter?(node.entry) ?? true {
            let d = target.distanceInMeters(to: node.entry.coordinate)
            if d < bestDistance {
                bestDistance = d
                bestEntry = node.entry
            }
        }

        let deltaDegrees = node.axis == 0
            ? (target.latitude - node.entry.latitude)
            : (target.longitude - node.entry.longitude)

        let first = deltaDegrees < 0 ? node.left : node.right
        let second = deltaDegrees < 0 ? node.right : node.left

        search(node: first, target: target, filter: filter, bestEntry: &bestEntry, bestDistance: &bestDistance)

        // Conservative degree-to-meter lower bound (~111,320 m per degree latitude; scaled by cos(lat) for longitude).
        let metersPerDegree: Double
        if node.axis == 0 {
            metersPerDegree = 110_574.0
        } else {
            let cosLat = max(0.05, cos(target.latitude * .pi / 180.0))
            metersPerDegree = 111_320.0 * cosLat
        }

        // Handle anti-meridian wrap conservatively.
        let minPlaneDistanceMeters = abs(deltaDegrees) * metersPerDegree
        if minPlaneDistanceMeters < bestDistance {
            search(node: second, target: target, filter: filter, bestEntry: &bestEntry, bestDistance: &bestDistance)
        }
    }
}

/// Offline K-D tree reverse geocoder with sub-locality, venue POI matching, and +-2h indoor GPS gap-filling.
public struct OfflineGeocoder: Sendable {
    private let cityTree: KDTree2D
    private let sublocalityTree: KDTree2D
    private let allEntries: [GeoEntry]
    private let venues: [GeoVenueEntry]

    public init(
        entries: [GeoEntry] = OfflineGeocoder.builtInEntries,
        venues: [GeoVenueEntry] = OfflineGeocoder.builtInVenues
    ) {
        let cities = entries.filter { !$0.isSublocality }
        let sublocalities = entries.filter { $0.isSublocality }
        self.cityTree = KDTree2D(entries: cities.isEmpty ? entries : cities)
        self.sublocalityTree = KDTree2D(entries: sublocalities)
        self.allEntries = entries
        self.venues = venues
    }

    /// Parses GeoNames TSV rows (`geonameid\tname\t...\tlat\tlon\tfeature_class\tfeature_code\tcountry_code...`) into GeoEntries.
    public static func loadGeoNamesTSV(from url: URL, countryNames: [String: String] = defaultCountryNames) throws -> [GeoEntry] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var entries: [GeoEntry] = []
        content.enumerateLines { line, _ in
            guard !line.isEmpty, !line.hasPrefix("#") else { return }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 9,
                  let lat = Double(cols[4]),
                  let lon = Double(cols[5]) else {
                return
            }
            let name = String(cols[1])
            let featureCode = String(cols[7])
            let countryCode = String(cols[8])
            let country = countryNames[countryCode] ?? countryCode
            let isSublocality = (featureCode == "PPLX")
            entries.append(
                GeoEntry(
                    name: name,
                    parentCity: nil,
                    country: country,
                    latitude: lat,
                    longitude: lon,
                    isSublocality: isSublocality
                )
            )
        }
        return entries
    }

    /// Resolves GPS coordinates to `City, Country`, optional `Sublocality`, and nearby offline venue within `maxVenueDistanceMeters`.
    public func resolve(
        coordinate: GPSCoordinate,
        maxCityDistanceMeters: Double = 75_000,
        maxSublocalityDistanceMeters: Double = 4_500,
        maxVenueDistanceMeters: Double = 250.0
    ) -> ResolvedLocation? {
        guard let nearestCity = cityTree.nearest(to: coordinate),
              nearestCity.distanceMeters <= maxCityDistanceMeters else {
            return nil
        }

        let city = nearestCity.entry.resolvedCityName
        let country = nearestCity.entry.country

        var sublocality: String?
        if let nearestSub = sublocalityTree.nearest(to: coordinate),
           nearestSub.distanceMeters <= maxSublocalityDistanceMeters,
           nearestSub.entry.resolvedCityName.caseInsensitiveCompare(city) == .orderedSame,
           nearestSub.entry.name.caseInsensitiveCompare(city) != .orderedSame {
            sublocality = nearestSub.entry.name
        }

        var matchedVenue: GeoVenueEntry?
        var bestVenueDist = maxVenueDistanceMeters
        for venue in venues {
            let d = coordinate.distanceInMeters(to: venue.coordinate)
            if d <= bestVenueDist {
                bestVenueDist = d
                matchedVenue = venue
            }
        }

        return ResolvedLocation(
            city: city,
            country: country,
            sublocality: sublocality ?? matchedVenue?.sublocality,
            venueName: matchedVenue?.venueName,
            venueCategory: matchedVenue?.category
        )
    }

    /// Resolves a user-supplied fallback venue or city query (e.g. `"National University of Singapore"` or `"Kyoto"`) offline.
    public func resolveFallbackQuery(_ query: String) -> (coordinate: GPSCoordinate, location: ResolvedLocation)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        func resolvedTuple(for venue: GeoVenueEntry) -> (coordinate: GPSCoordinate, location: ResolvedLocation) {
            (
                venue.coordinate,
                ResolvedLocation(
                    city: venue.city,
                    country: venue.country,
                    sublocality: venue.sublocality,
                    venueName: venue.venueName,
                    venueCategory: venue.category
                )
            )
        }

        // 1a. Exact match on venue name or alias first so short aliases (e.g. "NUS") aren't shadowed by substrings.
        if let exactVenue = venues.first(where: { v in
            v.venueName.lowercased() == lower || v.aliases.contains(where: { $0.lowercased() == lower })
        }) {
            return resolvedTuple(for: exactVenue)
        }

        // 1b. Substring match on venue name or aliases.
        if let partialVenue = venues.first(where: { v in
            v.venueName.lowercased().contains(lower)
                || lower.contains(v.venueName.lowercased())
                || v.aliases.contains(where: { lower.contains($0.lowercased()) })
        }) {
            return resolvedTuple(for: partialVenue)
        }

        // 2. Match against built-in cities & sub-localities (exact before substring).
        let matchedEntry = allEntries.first(where: { $0.name.lowercased() == lower })
            ?? allEntries.first(where: { lower.contains($0.name.lowercased()) })
        if let entry = matchedEntry {
            let coord = entry.coordinate
            let loc = resolve(coordinate: coord) ?? ResolvedLocation(
                city: entry.resolvedCityName,
                country: entry.country,
                sublocality: entry.isSublocality ? entry.name : nil
            )
            return (coord, loc)
        }

        return nil
    }

    /// Fills missing GPS coordinates for indoor photos using the closest geotagged item within +-2 hours.
    public func inferMissingGPS(
        for items: inout [AnalyzedMediaItem],
        maxWindowSeconds: TimeInterval = 7200
    ) {
        let geotaggedIndices = items.indices.filter { items[$0].rawGPS != nil }
            .sorted { items[$0].captureDate < items[$1].captureDate }

        guard !geotaggedIndices.isEmpty else { return }

        for idx in items.indices where items[idx].rawGPS == nil {
            let targetDate = items[idx].captureDate
            var closestGPS: GPSCoordinate?
            var smallestDelta = maxWindowSeconds + 1.0

            // Binary search starting position in sorted geotagged indices.
            var low = 0
            var high = geotaggedIndices.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let midDate = items[geotaggedIndices[mid]].captureDate
                if midDate < targetDate {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            for candidatePos in [low - 1, low] where (0..<geotaggedIndices.count).contains(candidatePos) {
                let geoIdx = geotaggedIndices[candidatePos]
                let delta = abs(items[geoIdx].captureDate.timeIntervalSince(targetDate))
                if delta <= maxWindowSeconds && delta < smallestDelta {
                    smallestDelta = delta
                    closestGPS = items[geoIdx].rawGPS
                }
            }

            if let inferred = closestGPS {
                items[idx].inferredGPS = inferred
            }
        }
    }

    /// Resolves `resolvedLocation` for all items that have raw or inferred GPS coordinates.
    public func resolveLocations(for items: inout [AnalyzedMediaItem]) {
        for idx in items.indices {
            if let gps = items[idx].effectiveGPS {
                items[idx].resolvedLocation = resolve(coordinate: gps)
            }
        }
    }

    // MARK: - Built-in World Cities & Major Sub-Localities

    public static let defaultCountryNames: [String: String] = [
        "JP": "Japan", "SG": "Singapore", "MY": "Malaysia", "US": "United States",
        "GB": "United Kingdom", "FR": "France", "KR": "South Korea", "TW": "Taiwan",
        "HK": "Hong Kong", "TH": "Thailand", "AU": "Australia", "DE": "Germany",
        "IT": "Italy", "ES": "Spain", "CA": "Canada", "ID": "Indonesia",
        "VN": "Vietnam", "CN": "China", "IN": "India", "NL": "Netherlands",
        "CH": "Switzerland", "NZ": "New Zealand"
    ]

    public static let builtInEntries: [GeoEntry] = [
        // Japan (Cities + Popular Dining/Sightseeing Sublocalities)
        GeoEntry(name: "Tokyo", country: "Japan", latitude: 35.6762, longitude: 139.6503),
        GeoEntry(name: "Shibuya", parentCity: "Tokyo", country: "Japan", latitude: 35.6595, longitude: 139.7004, isSublocality: true),
        GeoEntry(name: "Shinjuku", parentCity: "Tokyo", country: "Japan", latitude: 35.6938, longitude: 139.7034, isSublocality: true),
        GeoEntry(name: "Ginza", parentCity: "Tokyo", country: "Japan", latitude: 35.6717, longitude: 139.7649, isSublocality: true),
        GeoEntry(name: "Asakusa", parentCity: "Tokyo", country: "Japan", latitude: 35.7148, longitude: 139.7967, isSublocality: true),
        GeoEntry(name: "Roppongi", parentCity: "Tokyo", country: "Japan", latitude: 35.6628, longitude: 139.7314, isSublocality: true),
        GeoEntry(name: "Kyoto", country: "Japan", latitude: 35.0116, longitude: 135.7681),
        GeoEntry(name: "Gion", parentCity: "Kyoto", country: "Japan", latitude: 35.0037, longitude: 135.7786, isSublocality: true),
        GeoEntry(name: "Arashiyama", parentCity: "Kyoto", country: "Japan", latitude: 35.0156, longitude: 135.6776, isSublocality: true),
        GeoEntry(name: "Osaka", country: "Japan", latitude: 34.6937, longitude: 135.5023),
        GeoEntry(name: "Dotonbori", parentCity: "Osaka", country: "Japan", latitude: 34.6687, longitude: 135.5013, isSublocality: true),
        GeoEntry(name: "Umeda", parentCity: "Osaka", country: "Japan", latitude: 34.7025, longitude: 135.4960, isSublocality: true),
        GeoEntry(name: "Sapporo", country: "Japan", latitude: 43.0618, longitude: 141.3545),
        GeoEntry(name: "Fukuoka", country: "Japan", latitude: 33.5902, longitude: 130.4017),
        GeoEntry(name: "Nara", country: "Japan", latitude: 34.6851, longitude: 135.8048),
        GeoEntry(name: "Yokohama", country: "Japan", latitude: 35.4437, longitude: 139.6380),
        GeoEntry(name: "Nagoya", country: "Japan", latitude: 35.1815, longitude: 136.9066),
        GeoEntry(name: "Hiroshima", country: "Japan", latitude: 34.3853, longitude: 132.4553),
        GeoEntry(name: "Naha", country: "Japan", latitude: 26.2124, longitude: 127.6809),

        // Southeast Asia
        GeoEntry(name: "Singapore", country: "Singapore", latitude: 1.3521, longitude: 103.8198),
        GeoEntry(name: "Orchard", parentCity: "Singapore", country: "Singapore", latitude: 1.3048, longitude: 103.8318, isSublocality: true),
        GeoEntry(name: "Marina Bay", parentCity: "Singapore", country: "Singapore", latitude: 1.2834, longitude: 103.8607, isSublocality: true),
        GeoEntry(name: "Chinatown", parentCity: "Singapore", country: "Singapore", latitude: 1.2836, longitude: 103.8443, isSublocality: true),
        GeoEntry(name: "Tiong Bahru", parentCity: "Singapore", country: "Singapore", latitude: 1.2861, longitude: 103.8270, isSublocality: true),
        GeoEntry(name: "Kuala Lumpur", country: "Malaysia", latitude: 3.1390, longitude: 101.6869),
        GeoEntry(name: "Bukit Bintang", parentCity: "Kuala Lumpur", country: "Malaysia", latitude: 3.1466, longitude: 101.7116, isSublocality: true),
        GeoEntry(name: "George Town", country: "Malaysia", latitude: 5.4141, longitude: 100.3288),
        GeoEntry(name: "Johor Bahru", country: "Malaysia", latitude: 1.4927, longitude: 103.7414),
        GeoEntry(name: "Bangkok", country: "Thailand", latitude: 13.7563, longitude: 100.5018),
        GeoEntry(name: "Chiang Mai", country: "Thailand", latitude: 18.7883, longitude: 98.9853),
        GeoEntry(name: "Phuket", country: "Thailand", latitude: 7.8804, longitude: 98.3923),
        GeoEntry(name: "Ho Chi Minh City", country: "Vietnam", latitude: 10.8231, longitude: 106.6297),
        GeoEntry(name: "Hanoi", country: "Vietnam", latitude: 21.0278, longitude: 105.8342),
        GeoEntry(name: "Jakarta", country: "Indonesia", latitude: -6.2088, longitude: 106.8456),
        GeoEntry(name: "Denpasar", country: "Indonesia", latitude: -8.6705, longitude: 115.2126),

        // East Asia
        GeoEntry(name: "Seoul", country: "South Korea", latitude: 37.5665, longitude: 126.9780),
        GeoEntry(name: "Gangnam", parentCity: "Seoul", country: "South Korea", latitude: 37.4979, longitude: 127.0276, isSublocality: true),
        GeoEntry(name: "Myeongdong", parentCity: "Seoul", country: "South Korea", latitude: 37.5636, longitude: 126.9826, isSublocality: true),
        GeoEntry(name: "Busan", country: "South Korea", latitude: 35.1796, longitude: 129.0756),
        GeoEntry(name: "Taipei", country: "Taiwan", latitude: 25.0330, longitude: 121.5654),
        GeoEntry(name: "Ximending", parentCity: "Taipei", country: "Taiwan", latitude: 25.0422, longitude: 121.5081, isSublocality: true),
        GeoEntry(name: "Hong Kong", country: "Hong Kong", latitude: 22.3193, longitude: 114.1694),
        GeoEntry(name: "Central", parentCity: "Hong Kong", country: "Hong Kong", latitude: 22.2819, longitude: 114.1583, isSublocality: true),
        GeoEntry(name: "Beijing", country: "China", latitude: 39.9042, longitude: 116.4074),
        GeoEntry(name: "Shanghai", country: "China", latitude: 31.2304, longitude: 121.4737),

        // North America
        GeoEntry(name: "New York", country: "United States", latitude: 40.7128, longitude: -74.0060),
        GeoEntry(name: "SoHo", parentCity: "New York", country: "United States", latitude: 40.7233, longitude: -74.0030, isSublocality: true),
        GeoEntry(name: "Brooklyn", parentCity: "New York", country: "United States", latitude: 40.6782, longitude: -73.9442, isSublocality: true),
        GeoEntry(name: "San Francisco", country: "United States", latitude: 37.7749, longitude: -122.4194),
        GeoEntry(name: "Los Angeles", country: "United States", latitude: 34.0522, longitude: -118.2437),
        GeoEntry(name: "Seattle", country: "United States", latitude: 47.6062, longitude: -122.3321),
        GeoEntry(name: "Chicago", country: "United States", latitude: 41.8781, longitude: -87.6298),
        GeoEntry(name: "Austin", country: "United States", latitude: 30.2672, longitude: -97.7431),
        GeoEntry(name: "Boston", country: "United States", latitude: 42.3601, longitude: -71.0589),
        GeoEntry(name: "Honolulu", country: "United States", latitude: 21.3069, longitude: -157.8583),
        GeoEntry(name: "Vancouver", country: "Canada", latitude: 49.2827, longitude: -123.1207),
        GeoEntry(name: "Toronto", country: "Canada", latitude: 43.6532, longitude: -79.3832),
        GeoEntry(name: "Montreal", country: "Canada", latitude: 45.5017, longitude: -73.5673),

        // Europe
        GeoEntry(name: "London", country: "United Kingdom", latitude: 51.5072, longitude: -0.1276),
        GeoEntry(name: "Soho", parentCity: "London", country: "United Kingdom", latitude: 51.5136, longitude: -0.1365, isSublocality: true),
        GeoEntry(name: "Edinburgh", country: "United Kingdom", latitude: 55.9533, longitude: -3.1883),
        GeoEntry(name: "Paris", country: "France", latitude: 48.8566, longitude: 2.3522),
        GeoEntry(name: "Le Marais", parentCity: "Paris", country: "France", latitude: 48.8590, longitude: 2.3596, isSublocality: true),
        GeoEntry(name: "Nice", country: "France", latitude: 43.7102, longitude: 7.2620),
        GeoEntry(name: "Rome", country: "Italy", latitude: 41.9028, longitude: 12.4964),
        GeoEntry(name: "Milan", country: "Italy", latitude: 45.4642, longitude: 9.1900),
        GeoEntry(name: "Florence", country: "Italy", latitude: 43.7696, longitude: 11.2558),
        GeoEntry(name: "Venice", country: "Italy", latitude: 45.4408, longitude: 12.3155),
        GeoEntry(name: "Barcelona", country: "Spain", latitude: 41.3874, longitude: 2.1686),
        GeoEntry(name: "Madrid", country: "Spain", latitude: 40.4168, longitude: -3.7038),
        GeoEntry(name: "Berlin", country: "Germany", latitude: 52.5200, longitude: 13.4050),
        GeoEntry(name: "Munich", country: "Germany", latitude: 48.1351, longitude: 11.5820),
        GeoEntry(name: "Amsterdam", country: "Netherlands", latitude: 52.3676, longitude: 4.9041),
        GeoEntry(name: "Zurich", country: "Switzerland", latitude: 47.3769, longitude: 8.5417),

        // Oceania & South Asia
        GeoEntry(name: "Sydney", country: "Australia", latitude: -33.8688, longitude: 151.2093),
        GeoEntry(name: "Melbourne", country: "Australia", latitude: -37.8136, longitude: 144.9631),
        GeoEntry(name: "Auckland", country: "New Zealand", latitude: -36.8509, longitude: 174.7645),
        GeoEntry(name: "Queenstown", country: "New Zealand", latitude: -45.0312, longitude: 168.6626),
        GeoEntry(name: "Mumbai", country: "India", latitude: 19.0760, longitude: 72.8777),
        GeoEntry(name: "Bengaluru", country: "India", latitude: 12.9716, longitude: 77.5946)
    ]

    public static let builtInVenues: [GeoVenueEntry] = [
        // Singapore
        GeoVenueEntry(
            venueName: "University Cultural Centre (NUS)",
            category: "University",
            city: "Singapore",
            country: "Singapore",
            sublocality: "Kent Ridge",
            latitude: 1.3016,
            longitude: 103.7719,
            aliases: ["UCC", "University Cultural Centre"]
        ),
        GeoVenueEntry(
            venueName: "National University of Singapore",
            category: "University",
            city: "Singapore",
            country: "Singapore",
            sublocality: "Kent Ridge",
            latitude: 1.2966,
            longitude: 103.7764,
            aliases: ["NUS", "NUS Kent Ridge"]
        ),
        GeoVenueEntry(
            venueName: "Marina Bay Sands",
            category: "Landmark",
            city: "Singapore",
            country: "Singapore",
            sublocality: "Marina Bay",
            latitude: 1.2834,
            longitude: 103.8607,
            aliases: ["MBS"]
        ),
        GeoVenueEntry(
            venueName: "Jewel Changi Airport",
            category: "Landmark",
            city: "Singapore",
            country: "Singapore",
            sublocality: "Changi",
            latitude: 1.3602,
            longitude: 103.9898,
            aliases: ["Changi Airport", "Jewel"]
        ),
        GeoVenueEntry(
            venueName: "Gardens by the Bay",
            category: "Park",
            city: "Singapore",
            country: "Singapore",
            sublocality: "Marina Bay",
            latitude: 1.2816,
            longitude: 103.8636
        ),
        // Japan
        GeoVenueEntry(
            venueName: "Gion Corner",
            category: "Landmark",
            city: "Kyoto",
            country: "Japan",
            sublocality: "Gion",
            latitude: 35.0037,
            longitude: 135.7786
        ),
        GeoVenueEntry(
            venueName: "Fushimi Inari Taisha",
            category: "Landmark",
            city: "Kyoto",
            country: "Japan",
            sublocality: "Fushimi",
            latitude: 34.9671,
            longitude: 135.7727
        ),
        GeoVenueEntry(
            venueName: "Kiyomizu-dera",
            category: "Landmark",
            city: "Kyoto",
            country: "Japan",
            sublocality: "Higashiyama",
            latitude: 34.9949,
            longitude: 135.7850
        ),
        GeoVenueEntry(
            venueName: "Ichiran Dotonbori",
            category: "Restaurant",
            city: "Osaka",
            country: "Japan",
            sublocality: "Dotonbori",
            latitude: 34.6687,
            longitude: 135.5013
        ),
        GeoVenueEntry(
            venueName: "Tsukiji Outer Market",
            category: "Food Market",
            city: "Tokyo",
            country: "Japan",
            sublocality: "Tsukiji",
            latitude: 35.6655,
            longitude: 139.7707
        ),
        GeoVenueEntry(
            venueName: "Shibuya Sky",
            category: "Landmark",
            city: "Tokyo",
            country: "Japan",
            sublocality: "Shibuya",
            latitude: 35.6584,
            longitude: 139.7022
        ),
        GeoVenueEntry(
            venueName: "Senso-ji Temple",
            category: "Landmark",
            city: "Tokyo",
            country: "Japan",
            sublocality: "Asakusa",
            latitude: 35.7148,
            longitude: 139.7967
        )
    ]
}
