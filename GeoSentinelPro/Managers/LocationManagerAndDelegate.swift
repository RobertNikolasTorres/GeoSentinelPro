import SwiftUI
import Foundation
import Combine
import CoreLocation


extension LocationManager: CLLocationManagerDelegate {
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        
        if #available(iOS 14.0, *) {
            accuracyAuthorization = manager.accuracyAuthorization
            
            if accuracyAuthorization == .reducedAccuracy {
                showPreciseLocationPrompt = true
                StorageManager.shared.addLog(DebugLog(event: .accuracyChange, details: "⚠️ Reduced accuracy mode - prompt for precise location"))
            }
        }
        
        let storage = StorageManager.shared
        storage.addLog(DebugLog(event: .authChange, details: "Authorization: \(authorizationStatus.description)"))
        
        switch authorizationStatus {
        case .authorizedWhenInUse:
            if !storage.settings.hasCompletedWhenInUseAuth {
                storage.settings.hasCompletedWhenInUseAuth = true
                storage.save()
            }
            // Show Always auth prompt after When In Use is granted
            if !storage.settings.hasPromptedForAlways {
                showAlwaysAuthPrompt = true
            }
            startMonitoring()
            
        case .authorizedAlways:
            storage.settings.hasPromptedForAlways = true
            storage.save()
            startMonitoring()
            
        case .denied, .restricted:
            stopAllMonitoring()
            storage.addLog(DebugLog(event: .authChange, details: "❌ Location access denied or restricted"))
            
        default:
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        
        // In battery saver mode, periodically recenter regions
        if StorageManager.shared.settings.batteryMode == .batterySaver {
            recenterRegions()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let geofenceId = UUID(uuidString: region.identifier),
              let geofence = StorageManager.shared.geofences.first(where: { $0.id == geofenceId }) else { return }
        
        let storage = StorageManager.shared
        var state = storage.geofenceStates[geofenceId] ?? GeofenceState(geofenceId: geofenceId, state: .unknown)
        
        // Check if snoozed
        if state.isSnoozing {
            storage.addLog(DebugLog(event: .rawEnter, geofenceName: geofence.name, details: "Ignored (snoozed until \(state.snoozedUntil?.formatted() ?? ""))"))
            return
        }
        
        // Cancel any pending exit timer
        if let exitTimer = exitTimers[geofenceId] {
            exitTimer.invalidate()
            exitTimers.removeValue(forKey: geofenceId)
            state.pendingExitStart = nil
            storage.addLog(DebugLog(event: .exitCancelled, geofenceName: geofence.name, details: "Exit cancelled - re-entered region"))
        }
        
        storage.addLog(DebugLog(event: .rawEnter, geofenceName: geofence.name, details: "Raw entry signal received"))
        
        state.state = .pendingEntry
        state.pendingEntryStart = Date()
        storage.updateState(state)
        
        // Start dwell timer
        let dwellTime = storage.settings.dwellSeconds
        dwellTimers[geofenceId]?.invalidate()
        dwellTimers[geofenceId] = Timer.scheduledTimer(withTimeInterval: dwellTime, repeats: false) { [weak self] _ in
            self?.confirmEntry(geofenceId: geofenceId, geofence: geofence)
        }
        
        storage.addLog(DebugLog(event: .dwellWait, geofenceName: geofence.name,
                               details: "Waiting \(Int(dwellTime))s for dwell confirmation"))
    }
    
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let geofenceId = UUID(uuidString: region.identifier),
              let geofence = StorageManager.shared.geofences.first(where: { $0.id == geofenceId }) else { return }
        
        let storage = StorageManager.shared
        var state = storage.geofenceStates[geofenceId] ?? GeofenceState(geofenceId: geofenceId, state: .unknown)
        
        // Check if snoozed
        if state.isSnoozing {
            storage.addLog(DebugLog(event: .rawExit, geofenceName: geofence.name, details: "Ignored (snoozed)"))
            return
        }
        
        // Cancel any pending entry timer
        if let dwellTimer = dwellTimers[geofenceId] {
            dwellTimer.invalidate()
            dwellTimers.removeValue(forKey: geofenceId)
            state.pendingEntryStart = nil
            storage.addLog(DebugLog(event: .dwellCancelled, geofenceName: geofence.name, details: "Dwell cancelled - exited before confirmation"))
        }
        
        storage.addLog(DebugLog(event: .rawExit, geofenceName: geofence.name, details: "Raw exit signal received"))
        
        state.state = .pendingExit
        state.pendingExitStart = Date()
        storage.updateState(state)
        
        // Start exit debounce timer
        let exitTime = storage.settings.exitDebounceSeconds
        exitTimers[geofenceId]?.invalidate()
        exitTimers[geofenceId] = Timer.scheduledTimer(withTimeInterval: exitTime, repeats: false) { [weak self] _ in
            self?.confirmExit(geofenceId: geofenceId, geofence: geofence)
        }
        
        storage.addLog(DebugLog(event: .exitDebounce, geofenceName: geofence.name,
                               details: "Waiting \(Int(exitTime))s for exit confirmation"))
    }
    
    private func confirmEntry(geofenceId: UUID, geofence: Geofence) {
        let storage = StorageManager.shared
        var state = storage.geofenceStates[geofenceId] ?? GeofenceState(geofenceId: geofenceId, state: .unknown)
        
        state.state = .inside
        state.lastEntryTime = Date()
        state.pendingEntryStart = nil
        storage.updateState(state)
        
        storage.addLog(DebugLog(event: .entered, geofenceName: geofence.name,
                               details: "✅ ENTERED confirmed after \(storage.settings.dwellSeconds)s dwell"))
        
        if geofence.notifyOnEntry && !state.isSnoozing {
            NotificationManager.shared.sendGeofenceNotification(
                title: "Entered: \(geofence.name)",
                body: "You've been inside for \(Int(storage.settings.dwellSeconds))s",
                geofenceId: geofenceId.uuidString,
                eventType: "entry"
            )
        }
        
        dwellTimers.removeValue(forKey: geofenceId)
    }
    
    private func confirmExit(geofenceId: UUID, geofence: Geofence) {
        let storage = StorageManager.shared
        var state = storage.geofenceStates[geofenceId] ?? GeofenceState(geofenceId: geofenceId, state: .unknown)
        
        state.state = .outside
        state.lastExitTime = Date()
        state.pendingExitStart = nil
        storage.updateState(state)
        
        storage.addLog(DebugLog(event: .exited, geofenceName: geofence.name,
                               details: "✅ EXITED confirmed after \(storage.settings.exitDebounceSeconds)s outside"))
        
        if geofence.notifyOnExit && !state.isSnoozing {
            NotificationManager.shared.sendGeofenceNotification(
                title: "Exited: \(geofence.name)",
                body: "You've been outside for \(Int(storage.settings.exitDebounceSeconds))s",
                geofenceId: geofenceId.uuidString,
                eventType: "exit"
            )
        }
        
        exitTimers.removeValue(forKey: geofenceId)
    }
    
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let geofenceId = UUID(uuidString: region.identifier),
              let geofence = StorageManager.shared.geofences.first(where: { $0.id == geofenceId }) else { return }
        
        let storage = StorageManager.shared
        var geoState = storage.geofenceStates[geofenceId] ?? GeofenceState(geofenceId: geofenceId, state: .unknown)
        
        let stateString = state == .inside ? "Inside" : state == .outside ? "Outside" : "Unknown"
        storage.addLog(DebugLog(event: .stateRequest, geofenceName: geofence.name,
                               details: "Current state: \(stateString)"))
        
        switch state {
        case .inside:
            geoState.state = .inside
        case .outside:
            geoState.state = .outside
        case .unknown:
            geoState.state = .unknown
        }
        
        storage.updateState(geoState)
    }
    
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        StorageManager.shared.addLog(DebugLog(event: .visit,
                                              details: "Visit detected: (\(visit.coordinate.latitude), \(visit.coordinate.longitude)) Arrival: \(visit.arrivalDate), Departure: \(visit.departureDate)"))
        
        // Reconcile state by requesting all region states
        requestStateForAllRegions()
    }
    
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let regionName = region?.identifier ?? "Unknown"
        StorageManager.shared.addLog(DebugLog(event: .error,
                                              details: "❌ Monitoring failed for \(regionName): \(error.localizedDescription)"))
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        StorageManager.shared.addLog(DebugLog(event: .error, details: "❌ Location manager error: \(error.localizedDescription)"))
    }
}
