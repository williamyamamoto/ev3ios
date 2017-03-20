//
//  Ev3Connection.swift
//  EV3BTSpike
//
//  Created by Andre on 21.04.16.
//  Copyright © 2016 Andre. All rights reserved.
//

import Foundation
import ExternalAccessory

/// callback if the connection has changed
public protocol Ev3ConnectionChangedDelegate: class {
    func ev3ConnectionChanged(connected: Bool)
}

/**
 Connection which handles all read and write operations on the bluetooth connection.
 Read and write ops are dispatched to a serial queue, which should execute the given 
 closures in order or at least wait, till one operation has finished. So no concurrent 
 access on the streams should happen.
 
 TODOS:
 - Connection seems to disconnect, if a large number of messages will arrive. Dont know
 if the problem is on the ev3 side, or a problem in the ios app
 
 - responses arrive sometimes too late - that means, if a command (with reply) was send, first no reply is read on the input stream (you can send the messages, also more than once). Than you send a message without reply, and the response will arrive. Very strange.
 
 - Sometimes the first command is executed twice, but it is definitly send only once by this app
 */
public class Ev3Connection : NSObject, StreamDelegate {
    
    var accessory: EAAccessory
    var session: EASession?
    
    /// max command buffer size
    let maxBufferSize = 2
    
    /// sleeping time after each command was send to ev3
    let connSleepTime = 0.125
    
    /// indicating if the connection is closed
    var isClosed = true
    
    /// informs the delegates if a report was received
    var reportReceivedDelegates = [Ev3ReportDelegate]()
    
    /// delegate to informate the brick, that the connection hase changed 
    /// (true -> connected, false -> disconnected)
    var connectionChangedDelegates = [Ev3ConnectionChangedDelegate]()
    
    /// flag which is indicating, that spase is available on the output stream, 
    /// but there was no data to write.
    private var canWrite = true
    
    /// trying to handle all messages in a another queue
    private let queue = DispatchQueue(label: "com.ev3ios.connection.queue")
    
    
    /// buffer for the input stream size, with size of 2
    private var sizeBuffer = [UInt8](repeating: 0x00, count: 2)
    
    /// buffer for appending data to write e.g. if currently no space
    /// is available on the stream
    private var writeBuffer = Array<NSData>()
    
    init(accessory: EAAccessory){
        self.accessory = accessory
    }
    
    /// checks if the given accessory supports the ev3 protocol
    public static func supportsEv3Protocol(accessory: EAAccessory) -> Bool {
        return accessory.protocolStrings.contains(Ev3Constants.supportedProtocol)
    }
    
    /// open the connection before using
    func open(){
        if !isClosed {
            return
        }
        
        session = EASession(accessory: self.accessory, forProtocol: Ev3Constants.supportedProtocol)
        
        session!.outputStream!.delegate = self
        session!.outputStream!.schedule(in: RunLoop.main, forMode: RunLoopMode.commonModes)
        session!.outputStream!.open()
        
        session!.inputStream!.delegate = self
        session!.inputStream!.schedule(in: RunLoop.main, forMode: RunLoopMode.commonModes)
        session!.inputStream!.open()
        
        isClosed = false
        
        for del in self.connectionChangedDelegates{
            del.ev3ConnectionChanged(connected: true)
        }
    }
    
    /// delegate for receiving reports received from the input stream
    func addEv3ReportDelegate(_ delegate: Ev3ReportDelegate) {
        reportReceivedDelegates.append(delegate)
    }
    
    /// delegate for receiving updates, if the connection has changed
    public func addEv3ConnectionChangedDelegate(delegate: Ev3ConnectionChangedDelegate){
        connectionChangedDelegates.append(delegate)
    }
    
    /// close the connection after use
    func close(){
        if isClosed {
            return
        }
        
        for del in self.connectionChangedDelegates{
            del.ev3ConnectionChanged(connected: false)
        }
        
        session?.outputStream?.close()
        session?.outputStream?.remove(from: RunLoop.main, forMode: RunLoopMode.defaultRunLoopMode)
        session?.outputStream?.delegate = nil
        
        session?.inputStream?.close()
        session?.inputStream?.remove(from: RunLoop.main, forMode: RunLoopMode.defaultRunLoopMode)
        session?.inputStream?.delegate = nil
        
        isClosed = true
    }
    
    // Dispatch stuff to read
    // https://developer.apple.com/library/ios/documentation/Performance/Reference/GCD_libdispatch_Ref/
    
    /// writes the data to the outputstream
    private func write(){
        if writeBuffer.count < 1 {
            return
        }

        canWrite = false
        
        if session?.outputStream?.hasSpaceAvailable == false {
            print("error: stream has no space available")
            return
        }
        
        let mData = writeBuffer.remove(at: 0)
        
        print("Writing data: ")
        print(ByteTools.asHexString(data: mData))
        
        var bytes = mData.bytes.bindMemory(to: UInt8.self, capacity: mData.length)

        var bytesLeftToWrite: NSInteger = mData.length
        
        let bytesWritten = session?.outputStream?.write(bytes, maxLength: bytesLeftToWrite)
        if bytesWritten == -1 || bytesWritten == nil{
            print("error while writing data to bt output stream")
            canWrite = true
            return // Some error occurred ...
        }
        
        bytesLeftToWrite -= bytesWritten!
        bytes = bytes.advanced(by: bytesWritten!)
        
        if bytesLeftToWrite > 0 {
            print("error: not enough space in stream")
            writeBuffer.insert(NSData(bytes: &bytes, length: bytesLeftToWrite), at: 0)

        }
        
        print("bytes written \(bytesWritten)")
        print("write buffer size: \(writeBuffer.count)")
        Thread.sleep(forTimeInterval: connSleepTime) //give the ev3 time - too much traffic will disconnect the bt connection
    }
    
    /// writes data to the output stream of a accessory. the operation is handled on a own serial queue, 
    /// so that no concurrent write ops should happen
    private func write(data: NSData) {
        DispatchQueue(label: "com.ev3ios.connection.queue").async {
            self.dismissCommandsIfNeeded()
            
            self.writeBuffer.append(data)
            if self.canWrite {
                self.write()
            }
        }
    }
    
    /// write a command to the outputstream
    func write(command: Ev3Command) {
        write(data: command.toBytes())
    }
    
    /// cleares the writebuffer if it exceeds a given maximum
    private func dismissCommandsIfNeeded(){
        if( writeBuffer.count > maxBufferSize){
            for _ in 1...maxBufferSize {
                writeBuffer.remove(at: 1)
            }
            print("cleared write buffer")
        }
    
    }
    
    /// reads the data from the inputstream if bytes are available. calls the delegates,
    /// with the received data
    private func readInBackground(){
        
        var result = session?.inputStream?.read(&sizeBuffer, maxLength: sizeBuffer.count)
        
        if(result! > 0) {
            // buffer contains result bytes of data to be handled
            let size: Int16 = Int16(sizeBuffer[1]) << 8 | Int16(sizeBuffer[0])
            
            if size > 0 {
                var buffer = [UInt8](repeating: 0x00, count: Int(size))
                result = session?.inputStream?.read(&buffer, maxLength: buffer.count)
                
                if result! < 1 {
                    print("error reading the input data with size: \(size)")
                    return
                }
                
                print("read data:")
                print(ByteTools.asHexString(data: NSData(bytes: buffer, length: buffer.count)))

                reportReceived(report: buffer)

            }
            else{
                print("error on input stream: reply size < 1")
            }
            
        } else {
            print("error on input stream, while reading reply size")
        }    
    }
    
    /// delegates for receiving the events for the input and outputstream
    /// reading and writing ops are dispatched to a serial queue.
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event){
        switch eventCode {
       
        case Stream.Event.hasBytesAvailable:
            DispatchQueue(label: "com.ev3ios.connection.queue").async {
                self.readInBackground()
            }
            break
            
        case Stream.Event.hasSpaceAvailable:
            DispatchQueue(label: "com.ev3ios.connection.queue").async {
                self.canWrite = true
                self.write()
            }

            break
            
        case Stream.Event.openCompleted:
            print("stream opened")
            break
            
        case Stream.Event.errorOccurred:
             print("error on stream")
            break
            
        default:
            print("connection event: \(eventCode.rawValue)")
            break
        }
    
    }
    
    //if running in background, this must be dispatched to the main queue
    private func reportReceived(report: [UInt8]){
        DispatchQueue.main.async {
            for delegate in self.reportReceivedDelegates {
                delegate.reportReceived(report: report)
            }
        }
    }

}




