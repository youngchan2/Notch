import AppKit
import Carbon

struct SpotifyReadResult {
    var track: Track?
    var errorCode: Int?

    var connection: Connection {
        switch errorCode {
        case nil: return track == nil ? .idle : .ready
        case Int(errAEEventWouldRequireUserConsent): return .needsPermission
        case Int(errAEEventNotPermitted): return .denied
        default: return .unavailable
        }
    }
}

enum SpotifyAutomation {
    static func read(processIdentifier: pid_t, prompt: Bool) -> SpotifyReadResult {
        // AEDeterminePermissionToAutomateTarget can wait indefinitely, even with
        // askUserIfNeeded=false. A real, read-only event has a reply timeout and
        // addresses this running process instead of resolving a stale bundle ID.
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(.init(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        property.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        property.setDescriptor(.init(typeCode: 0x70506c53), forKeyword: AEKeyword(keyAEKeyData)) // pPlS: player state
        property.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
        guard let object = property.coerce(toDescriptorType: typeObjectSpecifier) else {
            return SpotifyReadResult(errorCode: Int(errAECoercionFail))
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                          targetDescriptor: .init(processIdentifier: processIdentifier),
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        var options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract]
        if prompt { options = [.waitForReply, .canInteract] }
        else { options.insert(.init(rawValue: UInt(kAEDoNotPromptForUserConsent))) }
        do {
            let reply = try event.sendEvent(options: options, timeout: 4)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, error != 0 {
                return SpotifyReadResult(errorCode: Int(error))
            }
        } catch {
            return SpotifyReadResult(errorCode: (error as NSError).code)
        }

        let source = """
        with timeout of 4 seconds
            tell application id "com.spotify.client"
                if player state is stopped then return {}
                set t to current track
                return {id of t, name of t, artist of t, album of t, artwork url of t, duration of t, player position, player state as text, shuffling, repeating, shuffling enabled, repeating enabled}
            end tell
        end timeout
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return SpotifyReadResult(track: result.flatMap { Track.decode($0) },
                                 errorCode: error?[NSAppleScript.errorNumber] as? Int ?? (result == nil ? Int(errAECoercionFail) : nil))
    }
}
