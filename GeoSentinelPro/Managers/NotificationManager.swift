import Combine
import UserNotifications

class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    @Published var isAuthorized = false
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
            }
            
            if let error = error {
                StorageManager.shared.addLog(DebugLog(event: .error, details: "Notification auth error: \(error.localizedDescription)"))
            } else {
                StorageManager.shared.addLog(DebugLog(event: .notification, details: granted ? "✅ Notifications authorized" : "❌ Notifications denied"))
            }
        }
    }
    
    private func registerCategories() {
        let snoozeAction = UNNotificationAction(
            identifier: "SNOOZE_15",
            title: "Snooze 15m",
            options: []
        )
        
        let doneAction = UNNotificationAction(
            identifier: "MARK_DONE",
            title: "Mark as Done",
            options: [.destructive]
        )
        
        let geofenceCategory = UNNotificationCategory(
            identifier: "GEOFENCE_EVENT",
            actions: [snoozeAction, doneAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([geofenceCategory])
    }
    
    func sendGeofenceNotification(title: String, body: String, geofenceId: String, eventType: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "GEOFENCE_EVENT"
        content.userInfo = [
            "geofenceId": geofenceId,
            "eventType": eventType
        ]
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                StorageManager.shared.addLog(DebugLog(event: .error, details: "Failed to send notification: \(error.localizedDescription)"))
            } else {
                StorageManager.shared.addLog(DebugLog(event: .notification, details: "📲 Sent: \(title)"))
            }
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        guard let geofenceIdString = userInfo["geofenceId"] as? String,
              let geofenceId = UUID(uuidString: geofenceIdString) else {
            completionHandler()
            return
        }
        
        switch response.actionIdentifier {
        case "SNOOZE_15":
            StorageManager.shared.snoozeGeofence(geofenceId, minutes: 15)
            
        case "MARK_DONE":
            StorageManager.shared.addLog(DebugLog(event: .notification, details: "User marked notification as done"))
            
        default:
            break
        }
        
        completionHandler()
    }
}
