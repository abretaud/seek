require 'test_helper'

class SearchBiomodelsAdaptorTest < ActiveSupport::TestCase

  def setup
    mock_service_calls
  end

  test "search" do
    with_config_value :pubmed_api_email, "seek@sysmo-db.org" do
      adaptor = Seek::SearchBiomodelsAdaptor.new({})
      results = adaptor.search("yeast")
      assert_equal 10,results.count
      assert_equal 10,results.select{|r| r.kind_of?(Seek::BiomodelsSearchResult)}.count
      #results will all be the same due to the mocking of getSimpleModelById webservice call
      result = results.first
      assert_equal 34,result.authors.count
      assert_equal "Markus J Herrgård",result.authors.first
      assert_equal "A consensus yeast metabolic network reconstruction obtained from a community approach to systems biology.",result.title
      assert_equal "18846089",result.pubmed_id
      assert_match /Genomic data allow the large-scale manual or semi-automated assembly/,result.abstract
      assert result.date_published.kind_of?(Date)
      assert_equal Date.new(2008,10,11),result.date_published
    end
  end

  test "search no pubmed email" do
    with_config_value :pubmed_api_email,"" do
      adaptor = Seek::SearchBiomodelsAdaptor.new({})
      results = adaptor.search("yeast")
      assert_equal 0,results.count
    end
  end

  test "abstract adaptor" do
    adaptor = Seek::AbstractSearchAdaptor.new({})
    assert_raise(NoMethodError) do
      adaptor.search("yeast")
    end
  end


  private

  def mock_service_calls
    #WebMock.allow_net_connect!
    wsdl = File.new("#{Rails.root}/test/fixtures/files/mocking/biomodels.wsdl")
    stub_request(:get, "http://www.ebi.ac.uk/biomodels-main/services/BioModelsWebServices?wsdl").to_return(wsdl)

    response = File.new("#{Rails.root}/test/fixtures/files/mocking/biomodels_mock_response.xml")
    stub_request(:post, "http://www.ebi.ac.uk/biomodels-main/services/BioModelsWebServices").
        with(:headers => {'Soapaction'=>'"getModelsIdByName"'}).
        to_return(:status=>200,:body => response)

    response2 = File.new("#{Rails.root}/test/fixtures/files/mocking/biomodels_mock_response2.xml")
    stub_request(:post, "http://www.ebi.ac.uk/biomodels-main/services/BioModelsWebServices").
        with(:headers => {'Soapaction'=>'"getModelsIdByChEBIId"'}).
        to_return(:status=>200,:body => response2)

    response3 = File.new("#{Rails.root}/test/fixtures/files/mocking/biomodels_mock_response3.xml")
    stub_request(:post, "http://www.ebi.ac.uk/biomodels-main/services/BioModelsWebServices").
        with(:headers => {'Soapaction'=>'"getModelsIdByPerson"'}).
        to_return(:status=>200,:body => response3)

    response4 = File.new("#{Rails.root}/test/fixtures/files/mocking/biomodels_mock_response4.xml")
    stub_request(:post, "http://www.ebi.ac.uk/biomodels-main/services/BioModelsWebServices").
        with(:headers => {'Soapaction'=>'"getSimpleModelById"'}).
        to_return(:status=>200,:body => response4.read)

    ["18846089"].each do |pubmed_id|
      response = File.new("#{Rails.root}/test/fixtures/files/mocking/pubmed_#{pubmed_id}.xml")
      stub_request(:get, "http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&email=seek@sysmo-db.org&id=#{pubmed_id}&retmode=xml&tool=seek@sysmo-db.org").to_return(:status=>200,:body=>response.read)
    end

  end

end