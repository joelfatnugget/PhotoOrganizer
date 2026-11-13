import Foundation
import MapKit
import CoreLocation

/// Correlates GPS coordinates and fallback queries to specific venues/POIs using offline landmarks + Apple MapKit.
public struct VenueResolver: Sendable {
    public let enableMapKitLookup: Bool
    public let timeoutNanoseconds: UInt64

    public init(enableMapKitLookup: Bool = true, timeoutNanoseconds: UInt64 = 1_500_000_000) {
        self.enableMapKitLookup = enableMapKitLookup
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    /// Resolves fallback queries for non-GPS items and enriches spatial clusters (<= 75m) with Apple Maps POI names.
    public func enrichLocationsAndVenues(
        for items: inout [AnalyzedMediaItem],
        fallbackQuery: String,
        geocoder: OfflineGeocoder
    ) async {
        // 1. Apply fallback location query to items still lacking GPS.
        var cityLevelFallbackIndices = Set<Int>()
        let trimmedQuery = fallbackQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            let fallbackMatch = await resolveFallback(query: trimmedQuery, geocoder: geocoder)
            if let (coord, loc) = fallbackMatch {
                for idx in items.indices where items[idx].effectiveGPS == nil {
                    items[idx].inferredGPS = coord
                    items[idx].resolvedLocation = loc
                    if loc.venueName == nil {
                        cityLevelFallbackIndices.insert(idx)
                    }
                }
            }
        }

        // 2. Group items with GPS into spatial clusters (<= 75m) where venueName is still missing.
        guard enableMapKitLookup else { return }

        struct SpatialCluster {
            let center: GPSCoordinate
            var hasFood: Bool
            var indices: [Int]
        }

        var clusters: [SpatialCluster] = []
        for idx in items.indices {
            if cityLevelFallbackIndices.contains(idx) { continue }
            guard let gps = items[idx].effectiveGPS else { continue }
            if items[idx].resolvedLocation?.venueName != nil { continue }

            if let matchIdx = clusters.firstIndex(where: { $0.center.distanceInMeters(to: gps) <= 75.0 }) {
                clusters[matchIdx].indices.append(idx)
                clusters[matchIdx].hasFood = clusters[matchIdx].hasFood || items[idx].isFood
            } else {
                clusters.append(SpatialCluster(center: gps, hasFood: items[idx].isFood, indices: [idx]))
            }
        }

        // Limit MapKit POI queries to at most 15 distinct clusters per run to keep analysis fast.
        for cluster in clusters.prefix(15) {
            if let poi = await lookupNearestPOI(at: cluster.center, prioritizeDining: cluster.hasFood) {
                for idx in cluster.indices {
                    if var existing = items[idx].resolvedLocation {
                        existing.venueName = poi.name
                        existing.venueCategory = poi.category
                        items[idx].resolvedLocation = existing
                    } else if let fallbackCity = geocoder.resolve(coordinate: cluster.center) {
                        var updated = fallbackCity
                        updated.venueName = poi.name
                        updated.venueCategory = poi.category
                        items[idx].resolvedLocation = updated
                    }
                }
            }
        }
    }

    private func resolveFallback(
        query: String,
        geocoder: OfflineGeocoder
    ) async -> (GPSCoordinate, ResolvedLocation)? {
        if let offline = geocoder.resolveFallbackQuery(query) {
            return offline
        }
        guard enableMapKitLookup else { return nil }
        return await searchLocationWithMapKit(query: query, geocoder: geocoder)
    }

    private func searchLocationWithMapKit(
        query: String,
        geocoder: OfflineGeocoder
    ) async -> (GPSCoordinate, ResolvedLocation)? {
        let timeout = timeoutNanoseconds
        return await withTaskGroup(of: (GPSCoordinate, ResolvedLocation)?.self) { group in
            group.addTask {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                let search = MKLocalSearch(request: request)
                guard let response = try? await search.start(),
                      let item = response.mapItems.first else {
                    return nil
                }
                let loc = item.placemark.coordinate
                let coord = GPSCoordinate(latitude: loc.latitude, longitude: loc.longitude)
                let base = geocoder.resolve(coordinate: coord)
                let city = item.placemark.locality ?? base?.city ?? query
                let country = item.placemark.country ?? base?.country ?? "Unknown"
                let venue = item.name ?? base?.venueName
                let resolved = ResolvedLocation(
                    city: city,
                    country: country,
                    sublocality: item.placemark.subLocality ?? base?.sublocality,
                    venueName: venue,
                    venueCategory: base?.venueCategory ?? Self.friendlyCategory(item.pointOfInterestCategory)
                )
                return (coord, resolved)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func lookupNearestPOI(
        at coordinate: GPSCoordinate,
        prioritizeDining: Bool
    ) async -> (name: String, category: String?)? {
        let timeout = timeoutNanoseconds
        return await withTaskGroup(of: (name: String, category: String?)?.self) { group in
            group.addTask {
                let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let request = MKLocalPointsOfInterestRequest(center: center, radius: 100.0)
                let categories: [MKPointOfInterestCategory] = prioritizeDining
                    ? [.restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket]
                    : [.university, .museum, .park, .nationalPark, .beach, .hotel, .theater, .stadium, .zoo, .aquarium, .amusementPark, .restaurant, .cafe]
                request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)

                let search = MKLocalSearch(request: request)
                guard let response = try? await search.start(), !response.mapItems.isEmpty else {
                    return nil
                }
                let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let nearest = response.mapItems.min { lhs, rhs in
                    let dl = origin.distance(from: CLLocation(latitude: lhs.placemark.coordinate.latitude, longitude: lhs.placemark.coordinate.longitude))
                    let dr = origin.distance(from: CLLocation(latitude: rhs.placemark.coordinate.latitude, longitude: rhs.placemark.coordinate.longitude))
                    return dl < dr
                }
                guard let name = nearest?.name, !name.isEmpty else { return nil }
                return (name, Self.friendlyCategory(nearest?.pointOfInterestCategory))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func friendlyCategory(_ category: MKPointOfInterestCategory?) -> String? {
        guard let raw = category?.rawValue else { return nil }
        return raw.replacingOccurrences(of: "MKPOICategory", with: "")
    }
}
