import Foundation

// That a burst is one notification (design 3.5, footplate's Burst):
// what arrives within the window is told of together, led to the
// first arrival's row.

/// What arrives within this long of the first is told of with it, in
/// one notification: a crew member that writes three mails in a row
/// does not ring three times. A notification is this late at most.
let burstWindow: Duration = .seconds(3)

/// One notification: two lines, and where it leads in its yard.
struct Telling: Equatable, Sendable {
    var title: String
    var body: String
    /// The yard it tells of, by its name at the edge: a row of the
    /// same name in another yard is not the one it leads to.
    var yard: String
    var target: Target
}

/// What arrived since the last notification and is still to be told
/// of, of one kind: the Notifier keeps one a kind. Every paired yard
/// is followed, and a burst may be of several.
struct Burst: Sendable {
    private var news: [News] = []

    /// Takes `news` in, and says whether it is the first: the
    /// Notifier waits `burstWindow` from then and tells of all there
    /// is.
    mutating func add(_ news: News) -> Bool {
        self.news.append(news)
        return self.news.count == 1
    }

    /// Drops what waits of `yard`: it is followed no more, and a
    /// notification of it would lead nowhere.
    mutating func forget(yard: String) -> Bool {
        news.removeAll { $0.yard == yard }
        return news.isEmpty
    }

    /// All there is as one notification, or none when there is
    /// nothing. It leads to the first arrival's row, in the yard it
    /// arrived in. `named` is whether it says which yard: where
    /// several are paired, a sender alone does not; `titles` names
    /// each yard as the head line does, since a name at the edge is
    /// empty for the account's own. A burst of several yards always
    /// names each, each yard's part by itself.
    mutating func take(named: Bool, titles: [String: String] = [:]) -> Telling? {
        guard !news.isEmpty else { return nil }
        let all = news
        news = []
        let first = all[0]
        let titleOf: (String) -> String = { titles[$0] ?? $0 }
        var order: [String] = []
        var byYard: [String: [News]] = [:]
        for item in all {
            if byYard[item.yard] == nil { order.append(item.yard) }
            byYard[item.yard, default: []].append(item)
        }
        let told: (String, String)
        if order.count == 1 {
            told = ofOneYard(all, yard: named ? titleOf(first.yard) : nil)
        } else {
            let parts = order.map { "\(line(titleOf($0))): \(counted(byYard[$0]!))" }
            told = ("\(all.count) new in \(order.count) yards", parts.joined(separator: "; "))
        }
        return Telling(title: told.0, body: told.1, yard: first.yard, target: first.target)
    }
}

/// The two lines of a notification of one yard's `news`, which is not
/// empty: led by the yard's title where `yard` gives one.
private func ofOneYard(_ news: [News], yard: String?) -> (String, String) {
    let first = news[0]
    func lead(_ title: String) -> String {
        guard let yard else { return title }
        return "\(line(yard)) · \(title)"
    }
    if news.count == 1 {
        let title: String
        switch first.target {
        case .conversation:
            title = line(first.from)
        case .decision:
            title = first.from.isEmpty ? "A decision waits" : "A decision from \(line(first.from))"
        }
        return (lead(title), line(first.text))
    }
    if news.allSatisfy({ $0.kind == .mail && $0.from == first.from }) {
        // The newest says most of where the sender stands.
        return (lead("\(news.count) from \(line(first.from))"), line(news.last!.text))
    }
    let title = yard.map { "\(news.count) new in \(line($0))" } ?? "\(news.count) new in the yard"
    return (title, counted(news))
}

/// `news` of several kinds or senders in a line: how many of each,
/// mail by sender in the order it came.
private func counted(_ news: [News]) -> String {
    var parts: [(String, Int)] = []
    for item in news where item.kind == .mail {
        let part = "from \(line(item.from))"
        if let at = parts.firstIndex(where: { $0.0 == part }) {
            parts[at].1 += 1
        } else {
            parts.append((part, 1))
        }
    }
    var body = parts.map { "\($0.1) \($0.0)" }
    let decisions = news.count { $0.kind == .decision }
    if decisions == 1 { body.append("1 decision") }
    if decisions >= 2 { body.append("\(decisions) decisions") }
    return body.joined(separator: ", ")
}
