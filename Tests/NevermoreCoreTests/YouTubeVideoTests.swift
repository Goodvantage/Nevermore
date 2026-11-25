import Foundation
import NevermoreCore
import Testing

@Test(arguments: [
    "https://youtu.be/3TNpOD6bov8?si=tracking",
    "https://www.youtube.com/watch?feature=share&v=3TNpOD6bov8#fragment",
    "https://youtube.com:443/shorts/3TNpOD6bov8",
    "https://m.youtube.com/live/3TNpOD6bov8",
    "https://youtube.com/embed/3TNpOD6bov8?autoplay=1",
])
func recognizesYouTubeVideo(_ raw: String) throws {
    let url = try #require(URL(string: raw))
    let video = try #require(YouTubeVideo(url: url))
    #expect(video.id == "3TNpOD6bov8")
    #expect(video.embedURL.absoluteString == "https://www.youtube.com/embed/3TNpOD6bov8?playsinline=1")
}

@Test(arguments: [
    "http://youtu.be/3TNpOD6bov8",
    "https://youtube.com.example/watch?v=3TNpOD6bov8",
    "https://www.notyoutube.com/watch?v=3TNpOD6bov8",
    "https://youtu.be@evil.example/3TNpOD6bov8",
    "https://user@youtu.be/3TNpOD6bov8",
    "https://youtu.be:444/3TNpOD6bov8",
    "https://youtu.be//3TNpOD6bov8",
    "https://youtu.be/3TNpOD6bov8/other",
    "https://youtu.be/3TNpOD6%2Fov8",
    "https://www.youtube.com/watch?v=3TNpOD6bov8&v=dQw4w9WgXcQ",
    "https://www.youtube.com/watch?v=3TNpOD6bov",
    "https://www.youtube.com/watch?v=3TNpOD6bov%C3%A9",
    "https://www.youtube.com/playlist?list=3TNpOD6bov8",
    "https://www.youtube.com/redirect?v=3TNpOD6bov8",
])
func rejectsNonVideoYouTubeURL(_ raw: String) throws {
    let url = try #require(URL(string: raw))
    #expect(YouTubeVideo(url: url) == nil)
}
