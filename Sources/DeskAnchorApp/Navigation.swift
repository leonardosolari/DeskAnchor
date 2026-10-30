import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, exclusions, shortcuts, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "Generali"
        case .exclusions: return "Esclusioni"
        case .shortcuts: return "Scorciatoie"
        case .diagnostics: return "Diagnostica"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .exclusions: return "app.badge.checkmark"
        case .shortcuts: return "keyboard"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Personalizza il ripristino delle finestre e le automazioni."
        case .exclusions: return "Scegli le applicazioni da lasciare libere di gestire il proprio spazio."
        case .shortcuts: return "Le tue azioni e i tuoi layout, a portata di tastiera."
        case .diagnostics: return "Stato del sistema, archivio e registro delle operazioni."
        }
    }
}

enum SidebarDestination: Hashable {
    case layout(UUID)
    case settings(SettingsPage)
}
