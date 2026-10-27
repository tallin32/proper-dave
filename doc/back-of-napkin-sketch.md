# High Level Outline for Project "Proper Dave"
## Premise
Several applications exist whose purpose is to convey visual information in realtime to blind and visually impaired users. Information is obtained through the cameras, questions can be answered based on the information.
Example: "What objects are on this window sill that you can see?"
Example: "Tell me when the elevator is approaching my floor."
Example: "Tell me when I reach gate B62. I'm interested in coffee shops, restaurants, and Amex Centurion and SkyClub lounges. Let me know when I approach the gate or anything else on my list."
Example: "I'm looking for my blue T-Shirt with large text reading 'I ❤️ Melissa'. As I show you T-shirts, tell me which one I'm looking at."
Example: "Help me set the temperature on this thermostat."
The problem: These applications often give too frequent call-outs. Taking the airport gate example, the system will cheerily let you know, every three seconds, "I don't see Gate B62." … "I still don't see Gate B62, coffee shops, or lounges." … "There are people in front of you, but no Gate B62."
This project attempts to solve two problems:
- Only give relevant callouts. If the scenery hasn't changed, there's no need to describe essentially the same scene every five to ten seconds in response to a key frame and a single prompt.
- Allow, ultimately, for the search to be programmable. If the user searches for airport gates frequently, they can create a skill that teaches the model how to find airport gates, restaurant menus, appliance controls, etc., what information is relevant, and what information is unnecessary. A user trying to set their thermostat doesn't need to know that the camera view also contains a pair of dirty socks.
## High Level Components
- Computer Vision: This takes input from the selected camera (by default, either the device camera or Meta glasses), classifies the image into its components, and sends a representation to the classifier.
- Classifier: Lightweight, on-device model, using either on-device intelligence or a downloadable local model, such as Muse Glimmer. The ultimate goal of the classifier component is to compare the current frame with the last N frames (a default of 5 seems reasonable), and, given the user's overarching goal, determine whether the change warrants processing in the Cloud.
- Cloud model: Either a wrapper API or, during the development process, a library that calls the LLM directly (i.e. Muse Wonder, Muse Wonder Full) with the information deemed relevant by the Classifier, to return a spoken description of information to the user.
## How the Cloud Model will work
- Device side, it's an adapter for whatever model is in use.
- Initially, as mentioned, this can be calling the model directly.
- An eventual architectture:
  - API endpoint that takes the Classifier's data and calls the model
  - User accounts that track either a subscription to the service, or a BYOK where the user can supply their own LLM API tokens
    
This is an extremely high level overview. The first milestone is to create a minimum viable prototype suitable for hackathon submission. The main goals in the initial pass before coding are:
- Flesh out the initial components: image capture, classifier, large language model processor
- Define the API contract for an initial server that passes classifier information to the LLM
- Create TRDs for the various Components
Minimum viable prototype should allow me to step out with my Meta Glasses, ask the system to track the elevator in my apartment, step outside the building, and ask the system to keep track of the signs it sees and let me know when I'm near, say, the Verizon store, a specified restaurant, a metro station.
Include instrumentation. I should, as the developer, in the debug build be able to see a log of everything relevant that I would need to diagnose failures.
## Eventual Features
- Programmable skills. In the thermostat example, I want to be able to teach the system what to exclude when all I need to know is the status of a consumer appliance. This is not needful for MVP.
- A log viewer. This only needs to be present in the test builds.
The aim with this sketch is to have the development agent (Muse Code for this example) ask the questions is needs to in order to generate the TRDs for the image recognizer, the classifier, 
and both a prototype library that passes the information directly to the model and an API contract that can be spun up on an MVP server. MVP would be a server that could be run locally and accessed via port forwarding from a consumer internet connection. MVP version of the client, or test versions should allow the user to specify the server either by IP or DNS name, and port.
