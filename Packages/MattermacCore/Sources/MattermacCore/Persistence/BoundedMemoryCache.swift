import Foundation

/// Explicit cost bound rather than NSCache's advisory totalCostLimit. Owners supply decoded cost
/// (for images: bytesPerRow * height), not compressed download size. Main-actor UI ownership.
@MainActor public final class BoundedMemoryCache<Value> {
  private var values: [String: (value: Value, cost: Int)] = [:]
  private var order: [String] = []
  public private(set) var totalCost = 0
  public let limit: Int
  public init(limit: Int = 32 * 1_024 * 1_024) { self.limit = max(0, limit) }
  public func value(for key: String) -> Value? {
    guard let item = values[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return item.value
  }
  public func insert(_ value: Value, for key: String, cost: Int) {
    if let old = values.removeValue(forKey: key) { totalCost -= old.cost }
    order.removeAll { $0 == key }
    guard cost > 0, cost <= limit else { return }
    while totalCost > limit - cost || values.count >= 256, let oldest = order.first {
      order.removeFirst()
      if let old = values.removeValue(forKey: oldest) { totalCost -= old.cost }
    }
    values[key] = (value, cost)
    order.append(key)
    totalCost += cost
  }
  public func removeAll() {
    values = [:]
    order = []
    totalCost = 0
  }
}
