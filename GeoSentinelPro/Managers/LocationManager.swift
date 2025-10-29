import Foundation
import Combine
import CoreLocation

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()
    
    let manager = CLLocationManager()
    var dwellTimers: [UUID: Timer] = [:]
    var exitTimers: [UUID: Timer] = [:]
    
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    @Published var currentLocation: CLLocation?
    @Published var isMonitoring = false
    @Published var showAlwaysAuthPrompt = false
    @Published var showPreciseLocationPrompt = false
    
    private override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        authorizationStatus = manager.authorizationStatus
        if #available(iOS 14.0, *) {
            accuracyAuthorization = manager.accuracyAuthorization
        }
    }
    
    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
        StorageManager.shared.addLog(DebugLog(event: .authChange, details: "Requested When In Use authorization"))
    }
    
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
        StorageManager.shared.settings.hasPromptedForAlways = true
        StorageManager.shared.save()
        StorageManager.shared.addLog(DebugLog(event: .authChange, details: "Requested Always authorization"))
    }
    
    func requestTemporaryFullAccuracy() {
        if #available(iOS 14.0, *) {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseLocationRequired") { error in
                if let error = error {
                    StorageManager.shared.addLog(DebugLog(event: .error, details: "Precise location request failed: \(error.localizedDescription)"))
                }
            }
        }
    }
    
    func startMonitoring() {
        let storage = StorageManager.shared
        let settings = storage.settings
        
        // Stop existing monitoring
        stopAllMonitoring()
        
        // Request location state for all regions on startup
        requestStateForAllRegions()
        
        let batteryMode = settings.batteryMode
        
        if batteryMode == .batterySaver {
            // Battery saver: Use significant change
            if settings.significantChangeEnabled {
                manager.startMonitoringSignificantLocationChanges()
                storage.addLog(DebugLog(event: .significantChange, details: "Started significant-change monitoring (Battery Saver)"))
            }
        } else {
            // High fidelity: Use standard location updates sparingly
            manager.startUpdatingLocation()
            storage.addLog(DebugLog(event: .system, details: "Started location updates (High Fidelity)"))
        }
        
        // Visit monitoring
        if settings.visitMonitoringEnabled {
            manager.startMonitoringVisits()
            storage.addLog(DebugLog(event: .visit, details: "Started visit monitoring"))
        }
        
        // Start monitoring regions
        startMonitoringRegions()
        
        isMonitoring = true
    }
    
    private func startMonitoringRegions() {
        let storage = StorageManager.shared
        let settings = storage.settings
        
        // Get enabled geofences, sorted by priority and distance
        var enabledGeofences = storage.geofences.filter { $0.isEnabled }
        
        // Sort by priority (higher first), then by distance to user
        if let userLocation = currentLocation {
            enabledGeofences.sort { geo1, geo2 in
                if geo1.priority != geo2.priority {
                    return geo1.priority > geo2.priority
                }
                let dist1 = userLocation.distance(from: CLLocation(latitude: geo1.latitude, longitude: geo1.longitude))
                let dist2 = userLocation.distance(from: CLLocation(latitude: geo2.latitude, longitude: geo2.longitude))
                return dist1 < dist2
            }
        }
        
        // Limit to maxMonitoredRegions (respecting iOS 20 limit)
        let regionsToMonitor = enabledGeofences.prefix(min(settings.maxMonitoredRegions, 20))
        
        for geofence in regionsToMonitor {
            manager.startMonitoring(for: geofence.region)
            storage.addLog(DebugLog(event: .regionMonitoring, geofenceName: geofence.name,
                                   details: "Started monitoring (radius: \(Int(geofence.radius))m, priority: \(geofence.priority))"))
        }
        
        let monitoredCount = regionsToMonitor.count
        let totalEnabled = enabledGeofences.count
        if totalEnabled > monitoredCount {
            storage.addLog(DebugLog(event: .system, details: "⚠️ Only monitoring \(monitoredCount) of \(totalEnabled) enabled geofences (limit reached)"))
        }
    }
    
    func requestStateForAllRegions() {
        for region in manager.monitoredRegions {
            manager.requestState(for: region)
        }
        StorageManager.shared.addLog(DebugLog(event: .stateRequest, details: "Requested state for \(manager.monitoredRegions.count) regions"))
    }
    
    func stopAllMonitoring() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        
        cancelAllTimers()
        isMonitoring = false
    }
    
    private func cancelAllTimers() {
        dwellTimers.values.forEach { $0.invalidate() }
        dwellTimers.removeAll()
        exitTimers.values.forEach { $0.invalidate() }
        exitTimers.removeAll()
    }
    
    func recenterRegions() {
        guard let location = currentLocation else { return }
        
        StorageManager.shared.addLog(DebugLog(event: .system, details: "Recentering regions around user location"))
        startMonitoringRegions()
    }
}
