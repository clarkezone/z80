//
//  StringExtensions.swift
//
//
//  Created by Tim Sneath on 6/15/23.
//

extension String {
    func padLeft(toLength: Int, withPad: String = " ") -> String {
        return String(repeating: withPad, count: toLength - self.count).appending(self)
    }
    
    func padRight(toLength: Int, withPad: String = " ") -> String {
        return self.padding(toLength: toLength, withPad: withPad, startingAt: 0)
    }
}
