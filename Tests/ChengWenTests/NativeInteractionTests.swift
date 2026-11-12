import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

final class NativeInteractionTests:XCTestCase {
    @MainActor private func model(_ root:URL,count:Int=0)->AppModel {
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in XCTFail("Native interaction tests must not issue music or account requests");return [:]})
        model.settings.directory=root.appendingPathComponent("audio-output").path
        model.tracks=(0..<count).map{index in
            AudioTrack(raw:["id":"track-\(index)","title":"\(index) · "+String(repeating:"合成音乐长标题 ",count:8),"artist":"Synthetic artist","album":String(repeating:"Synthetic album ",count:6),"source":MusicSource.available[index % MusicSource.available.count].id,"duration":index==0 ? "0:18":"3:20","ext":"mp3"])
        }
        return model
    }
    @MainActor private func mount<V:View>(_ view:V,width:CGFloat=880,height:CGFloat=320)->(NSWindow,NSHostingView<V>) {
        _=NSApplication.shared
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:view);window.contentView=host
        return (window,host)
    }
    @MainActor private func detach(_ window:NSWindow){window.makeFirstResponder(nil);window.contentView=nil;window.close()}
    @MainActor private func settle(_ view:NSView)async {
        view.layoutSubtreeIfNeeded();try? await Task.sleep(nanoseconds:40_000_000);view.layoutSubtreeIfNeeded()
    }
    @MainActor private func views<T:NSView>(_ root:NSView,_ type:T.Type)->[T] {((root as? T).map{[$0]} ?? [])+root.subviews.flatMap{views($0,type)}}
    @MainActor private func key(_ characters:String,modifiers:NSEvent.ModifierFlags=[],code:UInt16,in window:NSWindow)throws->NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code))
    }
    @MainActor func testActualTableHeaderCyclesOffMixedOnAndEmptyDisablesSelection()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-header-"+UUID().uuidString),model=model(root,count:3)
        var focus:String?
        let (window,host)=mount(NativeResultsTable(model:model,focusedTrackID:Binding(get:{focus},set:{focus=$0})))
        defer{detach(window);model.shutdown();try? FileManager.default.removeItem(at:root)}
        await settle(host)
        let scroll=try XCTUnwrap(views(host,NativeResultsScrollView.self).first),table=scroll.resultsTable,header=scroll.resultsHeader.selectAllButton
        XCTAssertEqual(table.numberOfRows,3);XCTAssertEqual(header.state,.off);XCTAssertTrue(header.isEnabled)
        XCTAssertTrue(header.allowsMixedState)
        XCTAssertEqual(header.accessibilityIdentifier(),"result-select-all")
        let rowCell=try XCTUnwrap(table.view(atColumn:0,row:0,makeIfNecessary:true))
        let first=try XCTUnwrap(views(rowCell,NSButton.self).first)
        first.performClick(nil);await settle(host)
        XCTAssertEqual(model.selection,["track-0"]);XCTAssertEqual(header.state,.mixed)
        header.performClick(nil);await settle(host)
        XCTAssertEqual(model.selection,Set(model.tracks.map(\.id)));XCTAssertEqual(header.state,.on)
        let selectedCell=try XCTUnwrap(table.view(atColumn:0,row:2,makeIfNecessary:true))
        XCTAssertEqual(views(selectedCell,NSButton.self).first?.state,.on)
        header.performClick(nil);await settle(host)
        XCTAssertTrue(model.selection.isEmpty);XCTAssertEqual(header.state,.off)
        model.tracks=[];await settle(host)
        XCTAssertEqual(table.numberOfRows,0);XCTAssertFalse(header.isEnabled);XCTAssertEqual(header.state,.off)
        header.performClick(nil);XCTAssertTrue(model.selection.isEmpty)
        XCTAssertGreaterThanOrEqual(header.frame.width,header.intrinsicContentSize.width-0.5)
        XCTAssertGreaterThanOrEqual(header.frame.height,header.intrinsicContentSize.height-0.5)
    }
    @MainActor func testStreamingRowsPreserveSelectedIDsAndHeaderBecomesMixed()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-stream-table-"+UUID().uuidString),model=model(root,count:2)
        let (window,host)=mount(NativeResultsTable(model:model,focusedTrackID:.constant(nil)))
        defer{detach(window);model.shutdown();try? FileManager.default.removeItem(at:root)}
        await settle(host)
        let scroll=try XCTUnwrap(views(host,NativeResultsScrollView.self).first)
        scroll.resultsHeader.selectAllButton.performClick(nil);await settle(host)
        XCTAssertEqual(model.selection,["track-0","track-1"])
        model.tracks.append(AudioTrack(raw:["id":"later","title":"Later streamed song","source":"qq"]))
        await settle(host)
        XCTAssertEqual(scroll.resultsTable.numberOfRows,3)
        XCTAssertEqual(model.selection,["track-0","track-1"])
        XCTAssertEqual(scroll.resultsHeader.selectAllButton.state,.mixed)
        XCTAssertEqual(scroll.resultsTable.selectedRowIndexes,IndexSet([0,1]))
        scroll.resultsHeader.selectAllButton.performClick(nil);await settle(host)
        XCTAssertTrue(model.allSelected);XCTAssertEqual(model.selection.count,3)
    }
    @MainActor func testCommandAUsesFocusedTableAndNeverChangesSearchEditorSelection()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-focused-select-"+UUID().uuidString),model=model(root,count:4)
        var text="Synthetic piano",focus:String?
        let (window,host)=mount(VStack{
            NativeSearchField(text:Binding(get:{text},set:{text=$0}),label:"焦点搜索",onSearch:{XCTFail("Selection must not search")}).frame(height:28)
            NativeResultsTable(model:model,focusedTrackID:Binding(get:{focus},set:{focus=$0}))
        })
        defer{detach(window);model.shutdown();try? FileManager.default.removeItem(at:root)}
        await settle(host)
        let field=try XCTUnwrap(views(host,NSSearchField.self).first),table=try XCTUnwrap(views(host,NativeResultsTableView.self).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor=try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        XCTAssertEqual(editor.selectedRange(),NSRange(location:0,length:text.utf16.count))
        let commandA=try key("a",modifiers:.command,code:0,in:window)
        XCTAssertFalse(table.performKeyEquivalent(with:commandA))
        XCTAssertTrue(model.selection.isEmpty,"An unfocused table must not steal the editor's Command+A")
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(table.performKeyEquivalent(with:commandA));await settle(host)
        XCTAssertTrue(model.allSelected)
        XCTAssertTrue(table.performKeyEquivalent(with:try key("a",modifiers:[.command,.shift],code:0,in:window)));await settle(host)
        XCTAssertTrue(model.selection.isEmpty)
        table.selectAll(nil);await settle(host)
        XCTAssertTrue(model.allSelected,"The real menu's standard selectAll: action must also reach table selection")
        XCTAssertEqual(text,"Synthetic piano")
        XCTAssertNotEqual(field.focusRingType,.none);XCTAssertNotEqual(table.focusRingType,.none)
    }
    @MainActor func testTableNativeRangeSelectionAndSpaceUseStableTrackIDs()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-table-range-"+UUID().uuidString),model=model(root,count:8)
        var focused:String?
        let (window,host)=mount(NativeResultsTable(model:model,focusedTrackID:Binding(get:{focused},set:{focused=$0})))
        defer{detach(window);model.shutdown();try? FileManager.default.removeItem(at:root)}
        await settle(host)
        let table=try XCTUnwrap(views(host,NativeResultsTableView.self).first)
        table.selectRowIndexes(IndexSet(integersIn:2...4),byExtendingSelection:false);await settle(host)
        XCTAssertEqual(model.selection,["track-2","track-3","track-4"])
        table.selectRowIndexes(IndexSet(integer:6),byExtendingSelection:true);await settle(host)
        XCTAssertEqual(model.selection,["track-2","track-3","track-4","track-6"])
        XCTAssertTrue(window.makeFirstResponder(table))
        table.keyDown(with:try key(" ",code:49,in:window));await settle(host)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.jobs.count,0);XCTAssertFalse(model.isProbing)
    }
    @MainActor func testDisabledTableDoesNotSelectOrActivateRowActions()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-disabled-table-"+UUID().uuidString),model=model(root,count:3)
        let (window,host)=mount(NativeResultsTable(model:model,focusedTrackID:.constant(nil)).disabled(true))
        defer{detach(window);model.shutdown();try? FileManager.default.removeItem(at:root)}
        await settle(host)
        let scroll=try XCTUnwrap(views(host,NativeResultsScrollView.self).first),table=scroll.resultsTable
        XCTAssertFalse(scroll.resultsHeader.selectAllButton.isEnabled)
        for column in [0,7] {
            let cell=try XCTUnwrap(table.view(atColumn:column,row:0,makeIfNecessary:true))
            for button in views(cell,NSButton.self){XCTAssertFalse(button.isEnabled);button.performClick(nil)}
        }
        table.selectAll(nil);table.keyDown(with:try key(" ",code:49,in:window))
        await settle(host)
        XCTAssertTrue(model.selection.isEmpty);XCTAssertTrue(model.jobs.isEmpty);XCTAssertFalse(model.isProbing)
    }
    @MainActor func testTableScrollAndSelectionSurviveProgressAppendAndShrinkToTwoRows()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-table-scroll-"+UUID().uuidString),model=model(root,count:80)
        let (window,host)=mount(NativeResultsTable(model:model,focusedTrackID:.constant("track-79")),height:280)
        defer{detach(window);model.shutdown();try? FileManager.default.removeItem(at:root)}
        await settle(host)
        let scroll=try XCTUnwrap(views(host,NativeResultsScrollView.self).first),table=scroll.resultsTable
        table.scrollRowToVisible(79);await settle(host)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY,0)
        let offset=scroll.contentView.bounds.origin
        model.selection=["track-78","track-79"];model.probes["track-79"]=ProbeStatus(state:"checking",detail:"Synthetic progress")
        await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.origin.y,offset.y,accuracy:1)
        XCTAssertEqual(model.selection,["track-78","track-79"])
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow:79)))
        model.tracks.append(AudioTrack(raw:["id":"track-80","title":"Appended","source":"qq"]))
        await settle(host)
        XCTAssertEqual(table.numberOfRows,81);XCTAssertEqual(scroll.contentView.bounds.origin.y,offset.y,accuracy:1)
        model.tracks=Array(model.tracks.suffix(2));model.selection=["track-79"]
        await settle(host)
        XCTAssertEqual(table.numberOfRows,2)
        XCTAssertEqual(scroll.contentView.bounds.minY,-scroll.headerOverlap,accuracy:1)
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow:0)))
        let cell=try XCTUnwrap(table.view(atColumn:1,row:0,makeIfNecessary:true))
        XCTAssertTrue((cell.toolTip ?? "").contains("79 ·"))
    }
    @MainActor func testTableHeaderDoesNotCoverFirstResult() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-table-header-layout-"+UUID().uuidString),model=model(root,count:50)
        let (window,host)=mount(NativeResultsTable(model:model,focusedTrackID:.constant(nil)),width:840,height:280)
        defer{detach(window);model.shutdown();try? FileManager.default.removeItem(at:root)}
        await settle(host)
        let scroll=try XCTUnwrap(views(host,NativeResultsScrollView.self).first)
        let headerClip=try XCTUnwrap(scroll.resultsHeader.superview)
        let firstInScroll = scroll.resultsTable.convert(scroll.resultsTable.rect(ofRow: 0), to: scroll)
        XCTAssertGreaterThanOrEqual(firstInScroll.minY, headerClip.frame.maxY - 0.5, "The floating header must not cover the first result")
        let first=scroll.resultsTable.rect(ofRow:0)
        let visible=scroll.contentView.bounds
        XCTAssertGreaterThanOrEqual(first.minY + 0.5, visible.minY)
        XCTAssertLessThanOrEqual(first.maxY, visible.maxY + 0.5)
    }
    @MainActor func testApplicationMenuKeepsResponderActionsAndNativeKeyboardEquivalents()throws {
        let owner=ApplicationDelegate(),menu=owner.buildMenu()
        let edit=try XCTUnwrap(menu.items.compactMap(\.submenu).first{$0.title=="编辑"})
        let selectAll=try XCTUnwrap(edit.items.first{$0.action==#selector(NSText.selectAll(_:))})
        XCTAssertNil(selectAll.target);XCTAssertEqual(selectAll.keyEquivalent,"a")
        XCTAssertEqual(selectAll.keyEquivalentModifierMask,.command)
        for name in ["剪切","复制","粘贴","撤销","重做"]{XCTAssertNil(try XCTUnwrap(edit.items.first{$0.title==name}).target)}
        XCTAssertEqual(edit.items.first{$0.title=="搜索音乐…"}?.keyEquivalent,"f")
        let view=try XCTUnwrap(menu.items.compactMap(\.submenu).first{$0.title=="显示"})
        XCTAssertEqual(view.items.first{$0.title=="搜索音乐"}?.keyEquivalent,"1")
        XCTAssertEqual(view.items.first{$0.title=="下载管理"}?.keyEquivalent,"2")
    }
    @MainActor func testFocusedIntegerEditingCommitsBoundsAndStepperSurvivesLosingFocus()async throws {
        var value=10
        let (window,host)=mount(NativeIntegerField(value:Binding(get:{value},set:{value=$0}),range:1...30,label:"Focused synthetic limit").frame(width:110,height:28),width:180,height:70)
        defer{detach(window)}
        await settle(host)
        let control=try XCTUnwrap(views(host,NativeIntegerControl.self).first)
        XCTAssertNotEqual(control.field.focusRingType,.none)
        XCTAssertTrue(window.makeFirstResponder(control.field))
        let editor=try XCTUnwrap(control.field.currentEditor() as? NSTextView)
        editor.selectAll(nil);editor.insertText("999",replacementRange:editor.selectedRange())
        editor.doCommand(by:#selector(NSResponder.insertNewline(_:)))
        await settle(host)
        XCTAssertEqual(value,30);XCTAssertEqual(control.field.stringValue,"30")
        XCTAssertTrue(window.makeFirstResponder(control.field))
        let nextEditor=try XCTUnwrap(control.field.currentEditor() as? NSTextView)
        nextEditor.selectAll(nil);nextEditor.insertText("17",replacementRange:nextEditor.selectedRange())
        control.stepper.integerValue=18;control.stepper.sendAction(control.stepper.action,to:control.stepper.target)
        window.makeFirstResponder(nil);await settle(host)
        XCTAssertEqual(value,18,"Ending text editing must not restore the pre-stepper value")
        XCTAssertEqual(control.field.stringValue,"18")
    }
}
