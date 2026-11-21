import Foundation
import CoreGraphics
import CoreText
import SwiftUI

/// Native, selectable text with wrapped table cells and repeated headers on continuation pages.
public enum StorySummaryPDF {
    public struct Typography {
        public let title: CTFont
        public let heading: CTFont
        public let body: CTFont
        public let ink: CGColor
        public let tableFill: CGColor

        public init(title: CTFont, heading: CTFont, body: CTFont, ink: CGColor, tableFill: CGColor) {
            self.title = title
            self.heading = heading
            self.body = body
            self.ink = ink
            self.tableFill = tableFill
        }
    }

    @MainActor public static func renderSummary(_ summary: StorySharedSummary, title: String, patientName: String?, typography: Typography? = nil) throws -> Data {
        try render(text: summary.text, title: title, generatedAt: summary.generatedAt, patientName: patientName, labs: summary.labReadings ?? [], bulletDates:summary.bulletDates ?? [], typography: typography) { series, context, rect in
            let renderer = ImageRenderer(content: StoryLabSparkline(series).frame(width: rect.width, height: rect.height).environment(\.colorScheme, .light))
            renderer.render { _, paint in
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY)
                paint(context)
                context.restoreGState()
            }
        }
    }
    public static func render(text:String,title:String,generatedAt:Date,patientName:String?=nil,labs:[StoryLabReading]=[],bulletDates:[StorySummaryBulletDate]=[],typography:Typography?=nil,drawChart:((StoryLabSeries,CGContext,CGRect)->Void)?=nil) throws -> Data {
        let output=NSMutableData();var page=CGRect(x:0,y:0,width:612,height:792)
        guard let consumer=CGDataConsumer(data:output as CFMutableData),let context=CGContext(consumer:consumer,mediaBox:&page,nil) else {throw StoryEditError.invalidMutation}
        let ink=typography?.ink ?? CGColor(red:0.282,green:0.239,blue:0.247,alpha:1)
        let wash=typography?.tableFill ?? CGColor(red:1,green:0.933,blue:0.812,alpha:1)
        let rule=CGColor(red:0.88,green:0.85,blue:0.83,alpha:1)
        let secondary=CGColor(red:0.443,green:0.392,blue:0.408,alpha:1)
        let accent=CGColor(red:0.651,green:0.2,blue:0.188,alpha:1)
        var y:CGFloat=740;var pageNumber=0
        func attributed(_ text:String,size:CGFloat=10.5,bold:Bool=false,color:CGColor?=nil,displayTitle:Bool=false)->NSAttributedString {
            var spacing:CGFloat=2
            let style=withUnsafePointer(to:&spacing) {pointer in
                var setting=CTParagraphStyleSetting(spec:.lineSpacingAdjustment,valueSize:MemoryLayout<CGFloat>.size,value:pointer)
                return CTParagraphStyleCreate(&setting,1)
            }
            let face = displayTitle ? typography?.title : (bold ? typography?.heading : typography?.body)
            let font = face.map { CTFontCreateCopyWithAttributes($0, size, nil, nil) }
                ?? CTFontCreateWithName((displayTitle ? "Georgia" : bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            return NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color ?? ink,NSAttributedString.Key(kCTParagraphStyleAttributeName as String):style])
        }
        func height(_ value:NSAttributedString,width:CGFloat)->CGFloat {
            ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(value),CFRange(location:0,length:0),nil,CGSize(width:width,height:1000000),nil).height)+2
        }
        @discardableResult func draw(_ value:NSAttributedString,offset:Int=0,rect:CGRect)->Int {
            let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),CFRange(location:offset,length:0),CGPath(rect:rect,transform:nil),nil)
            CTFrameDraw(frame,context);return CTFrameGetVisibleStringRange(frame).length
        }
        func newPage() throws {
            if pageNumber>0 {context.endPDFPage()}
            guard pageNumber<100 else {throw StoryEditError.invalidMutation}
            context.beginPDFPage(nil);pageNumber+=1;y=740
            context.setFillColor(CGColor(gray:1,alpha:1));context.fill(page);context.textMatrix = .identity
            context.setStrokeColor(rule);context.setLineWidth(0.5)
            context.move(to:CGPoint(x:50,y:46));context.addLine(to:CGPoint(x:562,y:46));context.strokePath()
            context.textPosition=CGPoint(x:50,y:30)
            CTLineDraw(CTLineCreateWithAttributedString(attributed("Collective Care",size:8.5,bold:true,color:secondary)),context)
            let number=CTLineCreateWithAttributedString(attributed("\(pageNumber)",size:8.5,color:secondary))
            context.textPosition=CGPoint(x:562-CGFloat(CTLineGetTypographicBounds(number,nil,nil,nil)),y:30)
            CTLineDraw(number,context)
            if pageNumber > 1 {
                let runningTitle=[title,patientName?.isEmpty == false ? patientName:nil].compactMap{$0}.joined(separator:"  ·  ")
                let line=CTLineCreateWithAttributedString(attributed(runningTitle,size:9,color:secondary))
                let clipped=CTLineCreateTruncatedLine(line,512,.end,CTLineCreateWithAttributedString(attributed("…",size:9,color:secondary))) ?? line
                context.textPosition=CGPoint(x:50,y:749);CTLineDraw(clipped,context)
                context.setStrokeColor(rule);context.move(to:CGPoint(x:50,y:737));context.addLine(to:CGPoint(x:562,y:737));context.strokePath()
                y=718
            }
        }
        func paragraph(_ string:String,size:CGFloat=10.5,bold:Bool=false,color:CGColor?=nil,keepNext:CGFloat=0,bullet:Bool=false,displayTitle:Bool=false, accentRange: NSRange? = nil, accentColor: CGColor? = nil, dateTag: String? = nil, highlighted: Bool = false) throws {
            let value=NSMutableAttributedString(attributedString: attributed(string,size:size,bold:bold,color:color,displayTitle:displayTitle))
            if bullet, let separator=string.range(of:" — "), separator.lowerBound > string.startIndex {
                let topic=NSRange(string.startIndex..<separator.lowerBound,in:string)
                let boldAttributes=attributed(String(string[..<separator.lowerBound]),size:size,bold:true).attributes(at:0,effectiveRange:nil)
                if let font=boldAttributes[NSAttributedString.Key(kCTFontAttributeName as String)],topic.length>0 {
                    value.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),value:font,range:topic)
                }
            }
            if let accentRange, let accentColor {
                value.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: accentColor, range: accentRange)
            }
            if let dateTag {
                value.append(attributed("  ", size: size))
                // Nonbreaking spaces keep the complete date together when it wraps.
                let tag = NSMutableAttributedString(attributedString: attributed(
                    "\u{00a0}" + dateTag.replacingOccurrences(of: " ", with: "\u{00a0}") + "\u{00a0}",
                    size: 7.5, color: secondary))
                value.append(tag)
            }
            let inset: CGFloat = highlighted ? 12 : 0
            let indent: CGFloat = bullet ? 14 : 0
            let width = 512 - indent - inset * 2
            if bullet, let separator=string.range(of:" — ") {
                let prefix=value.attributedSubstring(from:NSRange(string.startIndex..<separator.upperBound,in:string))
                var hanging=min(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(prefix),nil,nil,nil)),width * 0.4)
                var lineSpacing:CGFloat=2
                let style=withUnsafePointer(to:&hanging) { indentPointer in
                    withUnsafePointer(to:&lineSpacing) { spacingPointer in
                        let settings=[CTParagraphStyleSetting(spec:.headIndent,valueSize:MemoryLayout<CGFloat>.size,value:indentPointer),CTParagraphStyleSetting(spec:.lineSpacingAdjustment,valueSize:MemoryLayout<CGFloat>.size,value:spacingPointer)]
                        return CTParagraphStyleCreate(settings,settings.count)
                    }
                }
                value.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String),value:style,range:NSRange(location:0,length:value.length))
            }
            let total=height(value,width:width)
            if y-58 < min(total+keepNext,682) {try newPage()}
            var offset=0
            while offset<value.length {
                let remaining=value.attributedSubstring(from:NSRange(location:offset,length:value.length-offset))
                let h=min(height(remaining,width:width),y-58)
                if highlighted {
                    context.setFillColor(CGColor(red:0.985,green:0.965,blue:0.93,alpha:1))
                    context.fill(CGRect(x:50,y:y-h-5,width:512,height:h+10))
                    context.setFillColor(accent);context.fill(CGRect(x:50,y:y-h-5,width:2.5,height:h+10))
                }
                if bullet && offset == 0 {
                    draw(attributed("•",size:size),rect:CGRect(x:50+inset,y:y-h,width:indent,height:h))
                }
                let count=draw(value,offset:offset,rect:CGRect(x:50+inset+indent,y:y-h,width:width,height:h))
                guard count>0 else {throw StoryEditError.invalidMutation}
                offset+=count;y-=h
                if offset<value.length {try newPage()}
            }
            y -= highlighted ? 8 : bullet ? 4 : 7
        }
        func table(headers:[String],rows:[[String]],series:[StoryLabSeries]=[],rowDates:[String?]=[],accentStripe:Bool=false) throws {
            let fractions:[CGFloat] = !series.isEmpty ? [0.24,0.24,0.34,0.18] : headers.count==2 ? [0.24,0.76] : headers.count==3 ? [0.22,0.60,0.18] : [0.25,0.25,0.23,0.27]
            let widths=fractions.map{$0*512}
            let headerValues=headers.map{attributed($0,size:10,bold:true,color:ink)}
            let showHeader = !(headers.count == 3 && headers.last == "Date")
            let headerHeight:CGFloat = showHeader ? zip(headerValues,widths).map{height($0.0,width:$0.1-10)}.max()!+10 : 0
            guard headerHeight<220 else {throw StoryEditError.invalidMutation}
            func header() {
                guard showHeader else { return }
                context.setFillColor(wash);context.fill(CGRect(x:50,y:y-headerHeight,width:512,height:headerHeight))
                var x:CGFloat=50
                for column in headers.indices {
                    draw(headerValues[column],rect:CGRect(x:x+5,y:y-headerHeight+5,width:widths[column]-10,height:headerHeight-10));x+=widths[column]
                }
                y-=headerHeight
            }
            if y-58<headerHeight+50 {try newPage()};header()
            for (index,row) in rows.enumerated() {
                let trend = series.indices.contains(index) ? series[index] : nil
                var chartHeight: CGFloat = trend?.points.isEmpty == false && drawChart != nil ? 16 : 0
                let values=row.enumerated().map { column, text -> NSAttributedString in
                    let isDateColumn = headers.count == 3 && headers.last == "Date" && column == 2
                    let value=NSMutableAttributedString(attributedString:attributed(text,size:isDateColumn ? 7.5 : 10,bold:column == 0,color:isDateColumn ? secondary : ink))
                    if column == 1, rowDates.indices.contains(index), let date = rowDates[index] {
                        value.append(attributed("  " + date.replacingOccurrences(of:" ",with:"\u{00a0}"),size:7.5,color:secondary))
                    }
                    if column == 1, let trend {
                        let label=[trend.latest.valueLabel,trend.latest.arrow].compactMap{$0}.joined(separator:" ")
                        let range=(text as NSString).range(of:label)
                        if range.location != NSNotFound {
                            let color=trend.latest.isImproving(in:labs) ? CGColor(red:0.12,green:0.43,blue:0.22,alpha:1) : CGColor(red:0.65,green:0.12,blue:0.10,alpha:1)
                            value.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),value:color,range:range)
                        }
                    }
                    return value
                };var offsets=Array(repeating:0,count:row.count)
                var pending=true
                while pending {
                    let heights=values.indices.map{column -> CGFloat in
                        if offsets[column]>=values[column].length {return 0}
                        return height(values[column].attributedSubstring(from:NSRange(location:offsets[column],length:values[column].length-offsets[column])),width:widths[column]-10) + (column == 2 ? chartHeight : 0)
                    }
                    let wanted=(heights.max() ?? 0)+10
                    if y-58<min(wanted,682-headerHeight) {try newPage();header()}
                    let rowHeight=min(wanted,y-58)
                    if accentStripe {
                        context.setFillColor(accent)
                        context.fill(CGRect(x:46,y:y-rowHeight,width:2.5,height:rowHeight))
                    }
                    var x:CGFloat=50;var progressed=0
                    for column in values.indices {
                        if column == 2, chartHeight > 0, let trend {
                            drawChart?(trend,context,CGRect(x:x+5,y:y-5-chartHeight,width:widths[column]-10,height:chartHeight))
                        }
                        if offsets[column]<values[column].length {
                            let count=draw(values[column],offset:offsets[column],rect:CGRect(x:x+5,y:y-rowHeight+5,width:widths[column]-10,height:rowHeight-10-(column == 2 ? chartHeight : 0)))
                            offsets[column]+=count;progressed+=count
                        }
                        x+=widths[column]
                    }
                    guard progressed>0 || values.allSatisfy({$0.length==0}) else {throw StoryEditError.invalidMutation}
                    chartHeight = 0
                    y-=rowHeight
                    context.setStrokeColor(rule);context.setLineWidth(0.4);context.move(to:CGPoint(x:50,y:y));context.addLine(to:CGPoint(x:562,y:y));context.strokePath()
                    pending=values.indices.contains{offsets[$0]<values[$0].length}
                    if pending {try newPage();header()}
                }
            }
            y-=12
        }
        try newPage()
        try paragraph("COLLECTIVE CARE",size:9,bold:true,color:accent,keepNext:90)
        y-=3
        let namedPatient=patientName?.trimmingCharacters(in:.whitespacesAndNewlines)
        try paragraph(namedPatient?.isEmpty == false ? namedPatient! : title,size:28,bold:true,color:ink,keepNext:65,displayTitle:true)
        if namedPatient?.isEmpty == false {try paragraph(title,size:12,bold:true,color:secondary,keepNext:40)}
        let dateFormatter=DateFormatter();dateFormatter.locale=Locale(identifier:"en_US_POSIX");dateFormatter.dateFormat="d MMM yyyy"
        try paragraph("Prepared " + dateFormatter.string(from:generatedAt),size:9,color:secondary,keepNext:30)
        y-=4
        context.setStrokeColor(rule);context.setLineWidth(0.7)
        context.move(to:CGPoint(x:50,y:y));context.addLine(to:CGPoint(x:562,y:y));context.strokePath()
        y-=16
        let abnormalLabs = labs.filter { $0.abnormalLabel != nil }
        let presentation = StorySummaryDocument.practitionerPresentation(text, hasAbnormalLabs: !abnormalLabs.isEmpty, bulletDates: bulletDates)
        let blocks = presentation.blocks
        var section=""
        var renderedRows=Set<Int>()
        for (index,block) in blocks.enumerated() {
            if renderedRows.contains(index) {continue}
            switch block {
            case let .heading(value,level):
                if level == 2 {section=value}
                y-=level==2 ? 11:4
                var following:CGFloat=24
                if index+1<blocks.count {
                    switch blocks[index+1] {
                    case let .paragraph(next), let .bullet(next):following=min(60,height(attributed(next),width:512))+8
                    case .heading:following=70
                    case let .table(headers,_):
                        let width:CGFloat=headers.count==2 ? 110:headers.count==3 ? 127:101
                        following=(headers.map{height(attributed($0,size:10,bold:true),width:width)}.max() ?? 16)+66
                    }
                }
                if level == 2, ["Comprehensive Health History","Care Plan & Interventions","Labs & Investigations"].contains(value) {following=max(following,130)}
                try paragraph(value,size:level==2 ? 13:11,bold:true,color:accent,keepNext:following)
                if level == 2, value != "Labs & Investigations" {
                    var rows:[[String]]=[]
                    var precedingTopic = ""
                    for nextIndex in (index+1)..<blocks.count {
                        if case .heading=blocks[nextIndex] {break}
                        guard case let .bullet(point)=blocks[nextIndex] else {break}
                        guard !StorySummaryDocument.topicAndNote(point).topic.isEmpty else {break}
                        let date=presentation.dates.first{StorySummaryDocument.shareShorthand($0.text)==point}?.displayLabel(history:value == "Comprehensive Health History") ?? "—"
                        let fields=StorySummaryDocument.topicAndNote(point)
                        let repeated = !fields.topic.isEmpty && fields.topic.caseInsensitiveCompare(precedingTopic) == .orderedSame
                        if value == "Comprehensive Health History" {
                            rows.append([date,repeated ? fields.note : point])
                        } else {
                            rows.append([repeated ? "" : fields.topic, fields.note, date == "—" ? "" : date])
                        }
                        precedingTopic = fields.topic
                        renderedRows.insert(nextIndex)
                    }
                    if !rows.isEmpty {try table(headers:value == "Comprehensive Health History" ? ["Year","Health events and course"] : [value == "Care Plan & Interventions" ? "Treatment / action" : "Topic","Notes","Date"],rows:rows,accentStripe:value == "Clinical Snapshot")}
                }
                if level == 2, value == "Labs & Investigations", !abnormalLabs.isEmpty {
                    let groups=StoryLabSeries.grouped(abnormalLabs)
                    let rows=groups.map { group -> [String] in
                        let reading=group.latest
                        let value=[reading.valueLabel,reading.arrow].compactMap{$0}.joined(separator:" ")
                        let status=reading.abnormalLabel?.replacingOccurrences(of:"↑ ",with:"").replacingOccurrences(of:"↓ ",with:"") ?? ""
                        let statusLine=[status,reading.isImproving(in:labs) ? "Improving" : nil].compactMap{$0}.joined(separator:" · ")
                        let latest=[value,statusLine,reading.dateLabel == "Date unknown" ? nil : reading.dateLabel].compactMap{$0}.joined(separator:"\n")
                        let history=group.readings.dropFirst().reversed().map { $0.dateLabel + " · " + $0.valueLabel }.joined(separator:"\n")
                        return [group.title,latest,history.isEmpty ? "—" : history,reading.interval.isEmpty ? "—" : reading.interval]
                    }
                    try table(headers:["Marker","Latest abnormal","Earlier results","Lab interval"],rows:rows,series:groups)
                }
            case let .bullet(value):
                let date=presentation.dates.first{StorySummaryDocument.shareShorthand($0.text)==value}?.displayLabel()
                try paragraph(value, bullet: true, dateTag: date, highlighted: section == "Clinical Snapshot")
            case let .paragraph(value):try paragraph(value, highlighted: section == "Clinical Snapshot")
            case let .table(headers,rows):try table(headers:headers,rows:rows)
            }
        }
        context.endPDFPage();context.closePDF();return output as Data
    }
}
