import AppKit
import Carbon
import WorkspaceCore

@MainActor final class ShortcutManager {
    var action: (KeyBinding) -> Void = { _ in }
    private var references: [EventHotKeyRef] = []
    private var bindings: [UInt32: KeyBinding] = [:]
    private var handler: EventHandlerRef?
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let binding = manager.bindings[id.id] { manager.action(binding) }
            }
            return noErr
        }, 1, &event, context, &handler)
    }
    func configure(_ new: [KeyBinding]) -> [String] {
        references.forEach { UnregisterEventHotKey($0) }; references = []; bindings = [:]
        var warnings: [String] = []
        for (index, binding) in new.enumerated() {
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                            EventHotKeyID(signature: 0x5350434C, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference); bindings[id] = binding }
            else { warnings.append("Scorciatoia \(binding.action) non registrata: potrebbe essere già usata (\(result)).") }
        }
        return warnings
    }
    static func description(_ binding: KeyBinding) -> String {
        let mods = binding.modifiers
        let labels: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",36:"↩",48:"⇥",49:"Spazio",51:"⌫",53:"Esc",123:"←",124:"→",125:"↓",126:"↑"]
        return (mods & UInt32(controlKey) != 0 ? "⌃" : "") + (mods & UInt32(optionKey) != 0 ? "⌥" : "") +
            (mods & UInt32(shiftKey) != 0 ? "⇧" : "") + (mods & UInt32(cmdKey) != 0 ? "⌘" : "") + (labels[binding.keyCode] ?? "Tasto \(binding.keyCode)")
    }
}
