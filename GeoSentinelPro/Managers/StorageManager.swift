import Combine
import Foundation

class StorageManager: ObservableObject {
    static let shared = StorageManager()
    
    @Published var geofences: [Geofence] = []
    @Published var geofenceStates: [UUID: GeofenceState] = [:]
    @Published var debugLogs: [DebugLog] = []
    @Published var settings = AppSettings()
    
    private let geofencesKey = "geosentinel_geofences"
    private let statesKey = "geosentinel_states"
    private let logsKey = "geosentinel_logs"
    private let settingsKey = "geosentinel_settings"
    
    private init() {
        loadData()
    }
    
    func loadData() {
        if let data = UserDefaults.standard.data(forKey: geofencesKey),
           let decoded = try? JSONDecoder().decode([Geofence].self, from: data) {
            geofences = decoded
        }
        
        if let data = UserDefaults.standard.data(forKey: statesKey),
           let decoded = try? JSONDecoder().decode([UUID: GeofenceState].self, from: data) {
            geofenceStates = decoded
        }
        
        if let data = UserDefaults.standard.data(forKey: logsKey),
           let decoded = try? JSONDecoder().decode([DebugLog].self, from: data) {
            debugLogs = decoded
        }
        
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }
    }
    
    func save() {
        if let encoded = try? JSONEncoder().encode(geofences) {
            UserDefaults.standard.set(encoded, forKey: geofencesKey)
        }
        if let encoded = try? JSONEncoder().encode(geofenceStates) {
            UserDefaults.standard.set(encoded, forKey: statesKey)
        }
        if let encoded = try? JSONEncoder().encode(debugLogs) {
            UserDefaults.standard.set(encoded, forKey: logsKey)
        }
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
    }
    
    func addGeofence(_ geofence: Geofence) {
        geofences.append(geofence)
        geofenceStates[geofence.id] = GeofenceState(geofenceId: geofence.id, state: .unknown)
        save()
    }
    
    func updateGeofence(_ geofence: Geofence) {
        if let index = geofences.firstIndex(where: { $0.id == geofence.id }) {
            geofences[index] = geofence
            save()
        }
    }
    
    func deleteGeofence(_ geofence: Geofence) {
        geofences.removeAll { $0.id == geofence.id }
        geofenceStates.removeValue(forKey: geofence.id)
        save()
    }
    
    func updateState(_ state: GeofenceState) {
        geofenceStates[state.geofenceId] = state
        save()
    }
    
    func addLog(_ log: DebugLog) {
        debugLogs.insert(log, at: 0)
        if debugLogs.count > 500 {
            debugLogs = Array(debugLogs.prefix(500))
        }
        save()
    }
    
    func clearLogs() {
        debugLogs.removeAll()
        save()
    }
    
    func snoozeGeofence(_ geofenceId: UUID, minutes: Int) {
        if var state = geofenceStates[geofenceId] {
            state.snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            updateState(state)
            if let geofence = geofences.first(where: { $0.id == geofenceId }) {
                addLog(DebugLog(event: .snoozed, geofenceName: geofence.name, details: "Snoozed for \(minutes) minutes"))
            }
        }
    }
}
