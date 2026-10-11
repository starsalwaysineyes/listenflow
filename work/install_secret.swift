import Foundation
import Security
let key = FileHandle.standardInput.readDataToEndOfFile()
let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.ListenFlow.llm", kSecAttrAccount as String: "https://api.deepseek.com"]
let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: key] as CFDictionary)
if status == errSecItemNotFound {
 var item = q
 item[kSecValueData as String] = key
 item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
 let added = SecItemAdd(item as CFDictionary, nil)
 if added != errSecSuccess { print("Keychain write failed: \(added)"); exit(1) }
} else if status != errSecSuccess { print("Keychain update failed: \(status)"); exit(1) }
print("API credential saved to Keychain.")
