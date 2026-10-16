// ya know, now that I think of it, I could prolly make the JVM also run in an app extension...
// update: added this functionality

import Foundation
import JessiJIT

@objc(JESSIJITHelperRequestHandler)
final class JITHelperRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let userInfo = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        let thread = Thread {
            JITHelperRunner.run(userInfo: userInfo)
            context.completeRequest(returningItems: nil)
        }
        thread.name = "JESSI.jit-helper"
        thread.stackSize = 4 << 20
        thread.start()
    }
}
