class SampleSerializer < PCSSerializer
  attribute :title
  attribute :attribute_map
  attribute :data, key: :attribute_map
  attribute :tags do
    serialize_annotations(object)
  end
  has_many :projects
  has_one :sample_type
  has_many :submitter
  has_many :projects
  has_many :data_files
  has_many :creators
  has_one :policy
  has_many :people
end
 
