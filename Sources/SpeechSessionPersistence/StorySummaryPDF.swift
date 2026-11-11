import Foundation
import CoreGraphics
import CoreText
import SwiftUI

/// Native, selectable text with wrapped table cells and repeated headers on continuation pages.
public enum StorySummaryPDF {
    @MainActor public static func renderSummary(_ summary: StorySharedSummary, title: String, patientName: String?) throws -> Data {
        try render(text: summary.text, title: title, generatedAt: summary.generatedAt, patientName: patientName, labs: summary.labReadings ?? []) { series, context, rect in
            let renderer = ImageRenderer(content: StoryLabSparkline(series).frame(width: rect.width, height: rect.height).environment(\.colorScheme, .light))
            renderer.render { _, paint in
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY)
                paint(context)
                context.restoreGState()
            }
        }
    }
    public static func render(text:String,title:String,generatedAt:Date,patientName:String?=nil,labs:[StoryLabReading]=[],drawChart:((StoryLabSeries,CGContext,CGRect)->Void)?=nil) throws -> Data {
        let output=NSMutableData();var page=CGRect(x:0,y:0,width:612,height:792)
        guard let consumer=CGDataConsumer(data:output as CFMutableData),let context=CGContext(consumer:consumer,mediaBox:&page,nil) else {throw StoryEditError.invalidMutation}
        let ink=CGColor(gray:0.12,alpha:1),green=CGColor(red:0.12,green:0.29,blue:0.24,alpha:1)
        let wash=CGColor(red:0.92,green:0.95,blue:0.92,alpha:1),rule=CGColor(gray:0.8,alpha:1)
        var y:CGFloat=740;var pageNumber=0
        func attributed(_ text:String,size:CGFloat=11,bold:Bool=false,color:CGColor?=nil)->NSAttributedString {
            var spacing:CGFloat=3
            let style=withUnsafePointer(to:&spacing) {pointer in
                var setting=CTParagraphStyleSetting(spec:.lineSpacingAdjustment,valueSize:MemoryLayout<CGFloat>.size,value:pointer)
                return CTParagraphStyleCreate(&setting,1)
            }
            return NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName((bold ? "Helvetica-Bold":"Helvetica") as CFString,size,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):color ?? ink,NSAttributedString.Key(kCTParagraphStyleAttributeName as String):style])
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
            CTLineDraw(CTLineCreateWithAttributedString(attributed("CollectiveCare · \(pageNumber)",size:9,color:CGColor(gray:0.45,alpha:1))),context)
        }
        func paragraph(_ string:String,size:CGFloat=11,bold:Bool=false,color:CGColor?=nil,keepNext:CGFloat=0) throws {
            let value=attributed(string,size:size,bold:bold,color:color)
            let total=height(value,width:512)
            if y-58 < min(total+keepNext,682) {try newPage()}
            var offset=0
            while offset<value.length {
                let remaining=value.attributedSubstring(from:NSRange(location:offset,length:value.length-offset))
                let h=min(height(remaining,width:512),y-58)
                let count=draw(value,offset:offset,rect:CGRect(x:50,y:y-h,width:512,height:h))
                guard count>0 else {throw StoryEditError.invalidMutation}
                offset+=count;y-=h
                if offset<value.length {try newPage()}
            }
            y-=8
        }
        func table(headers:[String],rows:[[String]],series:[StoryLabSeries]=[]) throws {
            let fractions:[CGFloat]=headers.count==2 ? [0.24,0.76] : headers.count==3 ? [0.28,0.34,0.38] : [0.25,0.25,0.23,0.27]
            let widths=fractions.map{$0*512}
            let headerValues=headers.map{attributed($0,size:10,bold:true,color:green)}
            let headerHeight=zip(headerValues,widths).map{height($0.0,width:$0.1-16)}.max()!+16
            guard headerHeight<220 else {throw StoryEditError.invalidMutation}
            func header() {
                context.setFillColor(wash);context.fill(CGRect(x:50,y:y-headerHeight,width:512,height:headerHeight))
                var x:CGFloat=50
                for column in headers.indices {
                    draw(headerValues[column],rect:CGRect(x:x+8,y:y-headerHeight+8,width:widths[column]-16,height:headerHeight-16));x+=widths[column]
                }
                y-=headerHeight
            }
            if y-58<headerHeight+50 {try newPage()};header()
            for (index,row) in rows.enumerated() {
                let trend = series.indices.contains(index) ? series[index] : nil
                var chartHeight: CGFloat = trend?.points.isEmpty == false && drawChart != nil ? 28 : 0
                let values=row.map{attributed($0,size:10.5)};var offsets=Array(repeating:0,count:row.count)
                var pending=true
                while pending {
                    let heights=values.indices.map{column -> CGFloat in
                        if offsets[column]>=values[column].length {return 0}
                        return height(values[column].attributedSubstring(from:NSRange(location:offsets[column],length:values[column].length-offsets[column])),width:widths[column]-16) + (column == 2 ? chartHeight : 0)
                    }
                    let wanted=(heights.max() ?? 0)+16
                    if y-58<min(wanted,682-headerHeight) {try newPage();header()}
                    let rowHeight=min(wanted,y-58)
                    var x:CGFloat=50;var progressed=0
                    for column in values.indices {
                        if column == 2, chartHeight > 0, let trend {
                            drawChart?(trend,context,CGRect(x:x+8,y:y-8-chartHeight,width:widths[column]-16,height:chartHeight))
                        }
                        if offsets[column]<values[column].length {
                            let count=draw(values[column],offset:offsets[column],rect:CGRect(x:x+8,y:y-rowHeight+8,width:widths[column]-16,height:rowHeight-16-(column == 2 ? chartHeight : 0)))
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
        try paragraph(title,size:22,bold:true,color:green)
        if let patientName,!patientName.isEmpty {try paragraph(patientName,size:14,bold:true,color:green)}
        let blocks=StorySummaryDocument.blocks(text)
        for (index,block) in blocks.enumerated() {
            switch block {
            case let .heading(value,level):
                y-=level==2 ? 8:2
                var following:CGFloat=24
                if index+1<blocks.count {
                    switch blocks[index+1] {
                    case let .paragraph(next):following=min(60,height(attributed(next),width:512))+8
                    case .heading:following=70
                    case let .table(headers,_):
                        let width:CGFloat=headers.count==2 ? 110:headers.count==3 ? 127:101
                        following=(headers.map{height(attributed($0,size:10,bold:true),width:width)}.max() ?? 16)+66
                    }
                }
                try paragraph(value,size:level==2 ? 14:11,bold:true,color:green,keepNext:following)
                if level == 2, value == "Labs & Investigations", !labs.isEmpty {
                    let series = StoryLabSeries.grouped(labs)
                    let rows = series.map { group -> [String] in
                        let latest = group.latest
                        let headline = [latest.valueLabel, latest.interpretation, latest.dateLabel].filter { !$0.isEmpty }.joined(separator: "\n")
                        let history = group.readings.count > 1 ? group.readings.reversed().map { $0.dateLabel + "  " + $0.valueLabel }.joined(separator: "\n") : "Single result"
                        return [group.title, headline, history, latest.interval.isEmpty ? "Not documented" : latest.interval]
                    }
                    try table(headers:["Test","Latest recorded result","History","Reference interval"],rows:rows,series:series)
                }
            case let .paragraph(value):try paragraph(value)
            case let .table(headers,rows):try table(headers:headers,rows:rows)
            }
        }
        context.endPDFPage();context.closePDF();return output as Data
    }
}
