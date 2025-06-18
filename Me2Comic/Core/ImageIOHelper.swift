//
//  ImageIOHelper.swift
//  Me2Comic
//
//  Created by me2 on 2025/6/17.
//

import Foundation
import ImageIO

enum ImageIOHelper {
    static func getImageDimensions(imagePath: String) -> (width: Int, height: Int)? {
        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return nil
        }
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    static func getBatchImageDimensions(imagePaths: [String]) -> [String: (width: Int, height: Int)] {
        var result: [String: (width: Int, height: Int)] = [:]
        for imagePath in imagePaths {
            if let dimensions = getImageDimensions(imagePath: imagePath) {
                result[imagePath] = dimensions
            }
        }
        return result
    }
}
