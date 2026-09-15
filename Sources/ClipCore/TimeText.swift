import Foundation

/// 列表里显示的时间：刚刚 / 5 分钟前 / 3 小时前 / 昨天 22:30 / 9月1日 08:05 / 2025年12月31日
public enum TimeText {
    public static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        // 不到 1 分钟；也包括系统时钟被往回调导致的负数
        if seconds < 60 {
            return "刚刚"
        }
        if seconds < 3600 {
            return "\(Int(seconds / 60)) 分钟前"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(Int(seconds / 3600)) 小时前"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "HH:mm"
            return "昨天 " + formatter.string(from: date)
        }
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
}
