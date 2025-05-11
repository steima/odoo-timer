//
//  OdooTimerApp.swift
//  OdooTimer
//
//  Created by Matthias Steinbauer on 11.05.25.
//

import SwiftUI

@main
struct OdooTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var loginWindow: NSWindow!
    var odooService = OdooService()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        showLoginWindow()
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Odoo Timer")
    }
    
    func showLoginWindow() {
        let loginView = LoginView(odooService: odooService, appDelegate: self) {
            self.loadTasksIntoMenu()
        }
        let hostingController = NSHostingController(rootView: loginView)
        loginWindow = NSWindow(contentViewController: hostingController)
        loginWindow.makeKeyAndOrderFront(nil)
        loginWindow.title = "Odoo Timer"
        loginWindow.center()
    }
    
    func closeLoginWindow() {
        DispatchQueue.main.async {
            self.loginWindow.close()
        }
    }
    
    func loadTasksIntoMenu() {
        odooService.fetchTasks { result in
            DispatchQueue.main.async {
                let menu = NSMenu()
                
                switch result {
                case .success(let tasks):
                    for task in tasks {
                        let item = NSMenuItem(title: "\(task.projectName): \(task.name)", action: #selector(self.toggleTimer(_:)), keyEquivalent: "")
                        item.representedObject = task
                        item.target = self
                        menu.addItem(item)
                    }
                    menu.addItem(NSMenuItem.separator())
                case .failure(let error):
                    menu.addItem(NSMenuItem(title: "Fehler: \(error.localizedDescription)", action: nil, keyEquivalent: ""))
                }
                
                menu.addItem(NSMenuItem(title: "Beenden", action: #selector(self.quit), keyEquivalent: "q"))
                self.statusItem.menu = menu
            }
        }
    }
    
    @objc func toggleTimer(_ sender: NSMenuItem) {
        // guard let task = sender.representedObject as? OdooTask else { return }
        // print("Starte/Stopp Timer für Aufgabe: \(task.name) in Projekt: \(task.projectName)")
        print("Start Stop Timer nicht implementiert")
        // TODO: Zeitbuchung via Odoo API
    }
    
    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Login View

struct LoginView: View {
    @ObservedObject var odooService: OdooService
    var appDelegate: AppDelegate
    var onLoginSuccess: () -> Void
    
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Odoo Login").font(.headline)
            TextField("URL (z. B. https://mein.odoo.com)", text: $odooService.url)
            TextField("Datenbank", text: $odooService.db)
            TextField("Benutzername", text: $odooService.username)
            SecureField("API-Token", text: $odooService.apiToken)
            
            if let error = errorMessage {
                Text(error).foregroundColor(.red)
            }
            
            HStack(spacing: 12) {
                Button("Login") {
                    odooService.login { success, error in
                        if success {
                            onLoginSuccess()
                            appDelegate.closeLoginWindow()
                        } else {
                            self.errorMessage = error ?? "Unbekannter Fehler"
                        }
                    }
                }
                
                Button("Abbrechen") {
                    appDelegate.quit()
                }
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Odoo Service

class OdooService: ObservableObject {
    @Published var url = ""
    @Published var db = ""
    @Published var username = ""
    @Published var apiToken = ""
    
    private(set) var uid: Int?
    private(set) var sessionId: String?
    
    struct OdooTask: Identifiable {
        let id: Int
        let name: String
        let projectName: String
    }
    
    func login(completion: @escaping (Bool, String?) -> Void) {
        print("Logging in to \(url)/\(db) as \(username) ...")
        guard let endpoint = URL(string: "\(url)/jsonrpc") else {
            completion(false, "Ungültige URL")
            return
        }
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "call",
            "params": [
                "service": "common",
                "method": "login",
                "args": [
                    db, username, apiToken
                ]
            ],
            "id": 1
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data = data,
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = response["result"] as? Int {
                print("OK")
                self.uid = result
                completion(true, nil)
            } else {
                print("Failed")
                completion(false, "Login fehlgeschlagen")
            }
        }.resume()
    }
    
    func fetchTasks(completion: @escaping (Result<[OdooTask], Error>) -> Void) {
        guard let uid = uid,
              let endpoint = URL(string: "\(url)/jsonrpc") else {
            return completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nicht eingeloggt"])))
        }
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "call",
            "params": [
                "service": "object",
                "method": "execute_kw",
                "args": [
                    db,
                    uid,
                    apiToken,
                    "project.task",
                    "search_read",
                    [],
                    ["fields": ["name", "project_id"], "limit": 100]
                ]
            ],
            "id": 2
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data = data,
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = response["result"] as? [[String: Any]] {
                
                let tasks = result.compactMap { taskDict -> OdooTask? in
                    guard let id = taskDict["id"] as? Int,
                          let name = taskDict["name"] as? String,
                          let project = taskDict["project_id"] as? [Any],
                          let projectName = project.last as? String else {
                        return nil
                    }
                    return OdooTask(id: id, name: name, projectName: projectName)
                }
                completion(.success(tasks))
            } else {
                completion(.failure(error ?? NSError(domain: "", code: -1, userInfo: nil)))
            }
        }.resume()
    }
}
