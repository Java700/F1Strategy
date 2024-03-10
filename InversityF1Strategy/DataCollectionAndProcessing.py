
import openai
import torch
import whisper
from urllib.request import urlopen
import json
import sys
import time
import datetime
import numpy as np
from scipy.stats import norm


class DataHarvester:
    def __init__(self):
        self.large_model = whisper.load_model("large-v2")
        self.transcribing_device = "cuda"

        sessions = urlopen("https://api.openf1.org/v1/sessions")
        how_many_sessions = len(json.loads(sessions.read().decode('utf-8')))

        # I am transcribing files from 28 sessions therefore
        fraction_of_radio_transcribing = 28/how_many_sessions

        response = urlopen(f"https://api.openf1.org/v1/team_radio")
        decoded_response = response.read().decode('utf-8')
        self.radio_left_to_transcribe = len(decoded_response) * fraction_of_radio_transcribing
        print("Files to transcribe:", self.radio_left_to_transcribe)
        self.seconds_transcribed = 0
        self.total_transcribed = 0
        
        sessions = urlopen('https://api.openf1.org/v1/sessions?session_type=Race&year=2023')
        decoded_sessions = json.loads(sessions.read().decode('utf-8'))
        session_keys = []
        for session in decoded_sessions:
            session_keys.append(session['session_key'])
        self.session_keys = session_keys

    def collect_radio_data(self):
        received_drivers = urlopen('https://api.openf1.org/v1/drivers?session_key=9158')
        drivers = json.loads(received_drivers.read().decode('utf-8'))


        for driver in drivers:
            driver_number = driver['driver_number']
            driver_name = driver['last_name']

            team_radio_response = urlopen(f"https://api.openf1.org/v1/team_radio?driver_number={driver_number}")
            driver_radio = json.loads(team_radio_response.read().decode('utf-8'))

            with open(f"{driver_name}TeamRadio.txt", "a") as outfile:
                for recording in driver_radio:
                    with torch.cuda.device(self.transcribing_device):
                        self.process_recording(recording, outfile)
                outfile.close()

    def process_recording(self, single_api_response, txt_file):

        start = time.time()
        self.transcribe_audio(single_api_response, txt_file)
        self.radio_left_to_transcribe -= 1
        self.total_transcribed += 1
        end = time.time()
        duration = end - start
        total_duration = round(duration, 2) + self.seconds_transcribed
        expected_time_seconds = self.radio_left_to_transcribe * (total_duration / self.total_transcribed)
        print("\rTime Left: {}".format(DataHarvester.format_seconds(expected_time_seconds)), end="")

    def transcribe_audio(self, audio_dictionary, txt_file):
        audio_path = audio_dictionary['recording_url']
        transcribe = self.large_model.transcribe(audio_path)

        audio_dictionary["transcribed_audio"] = transcribe["text"]

         radio_communication_type = self.classify_audio(transcribe["text"])
         audio_dictionary["radio_communication_type"] = radio_communication_type

         probability = self.calculate_probability_of_being_accurate(transcribe, radio_communication_type)
         audio_dictionary["probability_of_noticeable_impact"] = probability

        json.dump(audio_dictionary, txt_file)
        txt_file.write("\n")

    @staticmethod
    def format_seconds(seconds):
        hours = seconds // 3600
        minutes = (seconds % 3600) // 60
        return f"{hours} hours, {minutes} minutes"

     def classify_audio(self, transcribed_audio):
         prompt = ("This is a transcription of an F1 drivers team radio message. Put it into one of the following "
                   "categories: Negative about car, Negative about strategy, Negative about tyres, Positive about car, "
                   "Positive about strategy, Positive about tyres, Encoded strategy, or Neutral. Encoded strategy "
                   "refers to when a driver says Plan A/ Plan B etc... Include only the name of the category in your "
                   "response and no other semantics. Here is the transcribed audio: ") + transcribed_audio
         response = openai.ChatCompletion.create(
             model="gpt-3.5-turbo",
             messages=[{"role": "user", "content": prompt}]
         )
        return response.choices[0].message.content.strip()

    """Probability Algorithm methods"""

    def check_if_communication_is_positive(self, classification_list):
        if classification_list[0] == "Positive":
            return True
        elif classification_list[0] == "Negative":
            return False
        elif classification_list[0] == "Neutral":
            return None

    def calculate_probability_of_being_accurate(self, original_api_response, classification_string):
        classification_list = classification_string.split()

        aspect_referring_to = classification_list[-1]
        is_positive = self.check_if_communication_is_positive(classification_list)
        if is_positive == None:
            return False
        session_key = original_api_response["session_key"]
        driver_number = original_api_response["driver_number"]
        date_said = datetime.datetime.fromisoformat(original_api_response["date"])

        gaps_to_leader = []
        
        """I will first figure out whether the communication was said after the chequered flag. This will determine how I calculate the accuracy of the team radio. I will calculate whether it is the end of the drivers race or not using their tyre stints instead of the end of the race time. This means even if a driver didn't finish a race and team radio occurred after they retired, the function will still consider this to be the end of their race even though the race is still going on."""
        stints = urlopen(f'https://api.openf1.org/v1/stints?session_key={session_key}&driver_number={driver_number}')
        decoded_stints = json.loads(stints.read().decode('utf-8'))
        last_stint = decoded_stints[-1]
        last_lap_completed = last_stint["lap_end"]
        lap_request = urlopen('https://api.openf1.org/v1/laps?session_key={session_key}&driver_number={driver_number}&lap_number={last_lap_completed}')
        decoded_lap_request = json.loads(lap_request.read().decode('utf-8'))
        date_of_finish = decoded_lap_request["date_start"] + datetime.timedelta(minutes=1)
        
        if date_said>date_of_finish:
            for i in range(6):
                check_date = date_said + datetime.timedelta(minutes=i)
                iso_check_date = check_date.isoformat()
                gap_to_leader = self.get_most_recent_gap_to_leader(session_key, iso_check_date, driver_number)
                gaps_to_leader.append(gap_to_leader)
                if i == 5:
                    """There are 4 events that could impact the gap to the leader that aren't related to what the
                     driver said on the radio. (Obviously more could have effected the gap to the leader, such as other non
                     tyre related problems, but these are much less significant than the events about to be explained and
                     would be negligible when calculating score from multiple examples)"""

                    """The 4 events are:
                    1-- The driver pitted
                    2-- The leader pitted
                    3-- There was a safety car
                    4-- This driver was the leader
                    
                    The reason that I am measuring gap to leader instead of lap times is because:
                    -- There are a lot more events that can impact lap time such as flags and weather
                    -- The structure of the API database makes it hard to query lap times at a specific date and time
                    -- Max Verstappen is a pretty consistent thing to measure off of
                    
                    Below I will account for these 4 possible events.
                    """

                    """1-- Check whether a pit stop occurred for this driver during this 5 minutes"""
                    driver_pit_time = 0
                    response = urlopen(
                        f'https://api.openf1.org/v1/pit?session_key={session_key}&driver_number={driver_number}&date>{original_api_response["date"]}&date<{iso_check_date}')
                    data = json.loads(response.read().decode('utf-8'))
                    if len(data) != 0:
                        for pit in data:
                            driver_pit_time += pit["pit_duration"]

                    """2-- Check whether a pit stop occurred for the leader during this 5 minutes. To do this first the the
                    driver in first needs to be determined. This is sometimes tricky, position data only gets updated when a
                    drivers position changes"""

                    response = urlopen(
                        f'https://api.openf1.org/v1/position?session_key={session_key}&position=1&date<{original_api_response["date"]}')
                    data = json.loads(response.read().decode('utf-8'))

                    first_place_change_before_radio = data[-1]
                    time_of_radio_1st_place = first_place_change_before_radio["driver_number"]

                    leader_pit_time = 0
                    response = urlopen(
                        f'https://api.openf1.org/v1/pit?session_key={session_key}&driver_number={time_of_radio_1st_place}&date>{original_api_response["date"]}&date<{iso_check_date}')
                    data = json.loads(response.read().decode('utf-8'))
                    if len(data) != 0:
                        for pit in data:
                            leader_pit_time += pit["pit_duration"]

                    """3-- Check whether there was a safety car"""
                    response = urlopen(
                        f'https://api.openf1.org/v1/race_control?category=SafteyCar&date>{original_api_response["date"]}&date<{iso_check_date}')
                    data = json.loads(response.read().decode('utf-8'))
                    if len(data) != 0:
                        was_safety_car = True

                    """4-- Now account for whether that driver was in first place. If this is the case, measure the time
                    off of second place"""

                    if time_of_radio_1st_place == driver_number:
                        response = urlopen(
                            f'https://api.openf1.org/v1/position?session_key={session_key}&position=2&date<{original_api_response["date"]}')
                        data = json.loads(response.read().decode('utf-8'))
                        driver_in_second = data[-1]["driver_number"]
                        gaps_to_leader = []
                        for j in range(1, 6):
                            gap_to_leader = self.get_most_recent_gap_to_leader(session_key, iso_check_date, driver_in_second)
                            gaps_to_leader.append(gap_to_leader)
                        """If the driver in first is this driver, the gaps to leader actually measures the gaps to
                        second, therefore increasing the gap is good for this specific driver, this reverse means the
                        list should be reversed."""
                        gaps_to_leader.reverse()
                        
            """After that code these variables contain the data I need to calcualte the drivers score.
            1. gaps_to_leader
            2. was_safety_car
            3. driver_pit_time
            4. leader_pit_time
            
            After some research Verstappen was on average 0.2s faster per lap compared to the rest of the grid. Since I am usually measuring off of his times I will account for this drift
            """
            
            """I will also give the first lap times after the communication was said more score compared to the last ones. First I will calculate the drivers drift from the leader. I will do this by calculating the 5 changes in gap_to_leader over the 5 minutes after the communication was said."""
            
            if was_safety_car:
                """If there was a saftey car it is better to assume the driver was being accurate and return 1, as the actual truth to the driver's statement would be undeterminable in this case"""
                return 1
            
            for difference_to_leader in gaps_to_leader:
                difference_to_leader += leader_pit_time
                difference_to_leader -= driver_pit_time
            
            gaps_in_intervals = []
            for i in range(len(numbers) - 1):
                gap_between_intervals = numbers[i+1] - numbers[i]
                """Account for 'Verstappen Drift'"""
                gap_between_intervals - 0.2
                gaps_in_intervals.append(gap_between_intervals)
                
            """I will now calculate the score off of the r value of the gap_between_intervals array. Therefore, if the driver said something negative and the r value is positive, or vice versa, there is a likely chance that what the driver said was not accurate at all."""
            
            r_value = self.calculate_r_value(gaps_in_intervals)
            
            """If the communication was negative and accurate, we would expect to see a r value of +1 in the difference in the gaps to the leader, if it was postive this would be -1"""
            
            """Actual r value = 0.432"""
            
            """The score will be worked out as 1 - (difference between r value and expected r value)/2. Dividing by two, because the range of possible r values is two. And (1 -) because the closer the correlation between r value and expected r value, the more accurate the communication"""
            
            if is_positive:
                r_value_difference = 1 - r_value
            else:
                r_value_difference = -1 - r_value

            score = 1 - r_value_difference/2
            return score
                        
        else:
            """If here it means that the driver's radio communication was after the race. If this is the case the calculation of the score will calculated using a normal distribution with a mean of their average position"""
            all_time_positions = []
            for session in self.session_keys:
                response = urlopen('https://api.openf1.org/v1/position?session_key={session}&driver_number={driver_number}')
                positions_in_race = json.loads(response.read().decode('utf-8'))
                position_finished = positions_in_race[-1]
                all_time_positions.append(position_finished)
            
            response = urlopen('https://api.openf1.org/v1/position?session_key={session_key}&driver_number={driver_number}')
            positions_in_race = json.loads(response.read().decode('utf-8'))
            place_finished = positions_in_race[-1]
                
            probability_of_position_occuring = self.after_race_normal_distribution(all_time_positions, place_finished)
            
            """I will take a positive race to be classified as a race in their top 25% of races and a negative race to be worse than 75% of their races."""
            
            if is_positive:
                predicted_result_based_on_communication = 0.25
            else:
                predicted_result_based_on_communication = 0.75
                
            difference = predicted_result_based_on_communication - probability_of_position_occuring
            
            return round(1 - difference, 3)
            
        
    def after_race_normal_distribution(self, all_time_positions, new_position):
        mean = np.mean(all_time_positions)
        standard_deviation = np.std(all_time_positions)

        z_score = (new_value - mean) / standard_deviation

        probability = norm.cdf(z_score)

        if new_value < mean:
            probability = 1 - probability

        return probability
        
    def calculate_r_value(data):

        data = np.array(data)
        mean = np.mean(data)
        
        standard_deviation = np.std(data)
        
        """Calculate the covariance matrix and the covariance value"""
        covariance_matrix = np.cov(data)
        covariance = covariance_matrix[0, 1]
        
        r_value = covariance / (standard_deviation**2)
        
        return r_value

    def get_most_recent_gap_to_leader(self, session_key, iso_check_date, driver_number):
        response = urlopen(
            f"https://api.openf1.org/v1/intervals?session_key={session_key}&driver_number={driver_number}&date>{iso_check_date}")
        data = json.loads(response.read().decode('utf-8'))
        most_recent_data = data[0]
        gap_to_leader = most_recent_data["gap_to_leader"]
        return gap_to_leader


if __name__ == "__main__":
    data_harvester = DataHarvester()
    data_harvester.collect_radio_data()
